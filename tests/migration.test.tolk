import "@stdlib/tvm-dicts"
import "@acton/crypto"
import "@acton/ffi"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@wrappers/WalletTrampoline.gen"
import "@wrappers/utils"
import "@contracts/WalletTg/WalletTg"
import "@contracts/WalletTg/errors"
import "@contracts/WalletTg/messages"
import "@contracts/WalletTg/revisions"

/*
    This file checks lazy storage migration from old C4 revisions to the active code.
    Migration should commit only on successful messages that reach Storage.load().
*/

const MIGRATION_TG_USER_ID = 580 as uint64
const MIGRATION_VALID_TG_SECRET_TAG = 0x1234567890 as uint128

struct MigrationFixture {
    wallet: WalletTrampoline
    deployer: Treasury
    receiver: Treasury
    keyPair: KeyPair
}

fun createTruncatedAssignFlagXEnvelope(
    req: SignedRequest<AllowedExternalMsg>,
): cell {
    var signature = req.signature as slice;
    return beginCell().storeRef(req.request.toCell()).storeSlice(signature.loadBits(511)).endCell();
}

// This checks the active code ABI, not runtime getter behavior. Calling a missing
// get method via Acton FFI is reported as a test-framework failure, so it cannot
// be asserted with a normal try/catch inside a passing test.
fun activeWalletCodeHasMethod(methodName: string): bool {
    val code = testing.getConfig().getParamRaw(CONFIG_KEY_OF_BYTECODE);
    var cs = code.beginParse();

    assert (cs.loadUint(8) == 0xff) throw 0;
    assert (cs.loadUint(8) == 0) throw 0;
    assert (cs.loadUint(13) == 0b1111010010100) throw 0;
    assert (cs.loadBool()) throw 0;

    val keyLen = cs.loadUint(10);
    val methods = cs.loadRef() as dict;
    val methodId = (ffi.crc16(methodName) & 0xffff) | 0x10000;
    val (_, found) = methods.uDictGet(keyLen, methodId);
    return found;
}

fun deployRev00WalletWithActivity(): MigrationFixture {
    val keyPair = crypto.generateKeyPair();
    val deployer = testing.treasury("migration-deployer");
    val receiver = testing.treasury("migration-receiver");

    // Start from production rev00: config points to old code and C4 uses OldStorage_00.
    setWalletBytecodeInConfig(Revision.Rev00_Initial);
    val wallet = deployRev00Wallet(keyPair, deployer, "setup deploy WalletTg trampoline with rev00 config");

    // Send a couple of valid rev00 requests so migration has non-trivial state to preserve.
    val first = wallet.requestExternal(
        prepareSendMessagesE(
            keyPair,
            seqnoHeader(0),
            [makeTransferToSend(receiver.address, ton("0.001"))],
        ),
    );
    expect(first).toBeAccepted();
    val firstTrace = first.unwrap();
    firstTrace.giveName("setup rev00 EXTERNAL transfer #1");
    expect(firstTrace).toHaveTx({
        from: wallet.address,
        to: receiver.address,
        value: ton("0.001"),
    });
    expect(wallet.seqno()).toEqual(1);

    val second = wallet.requestExternal(
        prepareSendMessagesE(
            keyPair,
            seqnoHeader(1),
            [makeTransferToSend(receiver.address, ton("0.001"))],
        ),
    );
    expect(second).toBeAccepted();
    val secondTrace = second.unwrap();
    secondTrace.giveName("setup rev00 EXTERNAL transfer #2");
    expect(secondTrace).toHaveTx({
        from: wallet.address,
        to: receiver.address,
        value: ton("0.001"),
    });
    expect(wallet.seqno()).toEqual(2);

    // Top up the old wallet before the config upgrade, like an existing production account.
    val topUpTrace = wallet.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: ton("1"), bounce: false },
    );
    topUpTrace.giveName("setup top up rev00 WalletTg");
    expect(topUpTrace).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet.address,
    });
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);

    return MigrationFixture { wallet, deployer, receiver, keyPair };
}

get fun `test migration: malformed assign flagX does not migrate before valid internal request`() {
    val fixture = deployRev00WalletWithActivity();

    // While config still points to rev00, AssignFlagX is an unknown message.
    val rev00Assign = fixture
        .wallet
        .requestExternal(
            prepareAssignFlagXE(
                fixture.keyPair,
                seqnoHeader(2),
                true,
            ),
        );
    expect(rev00Assign).toBeNotAccepted();
    expect(rev00Assign).toHaveExternalVmExitCode(Errors.InvalidOpcode);
    expect(fixture.wallet.seqno()).toEqual(2);
    expect(fixture.wallet.revision()).toEqual(Revision.Rev00_Initial);

    // The rev00 getter dictionary does not have flag_x yet, so calling it would fail.
    expect(activeWalletCodeHasMethod("flag_x")).toBeFalse();

    // Simulate validators upgrading config to rev01 while the account C4 stays rev00.
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    expect(activeWalletCodeHasMethod("flag_x")).toBeTrue();

    // The revision getter reads the raw C4 prefix, so it must still report rev00.
    expect(fixture.wallet.revision()).toEqual(Revision.Rev00_Initial);

    // The flagX getter migrates transiently inside get-method execution, but does not commit C4.
    expect(fixture.wallet.flagX()).toEqual(false);

    // A malformed external body fails before Storage.load(), so migration cannot happen.
    val malformedReq = prepareAssignFlagXE(
        fixture.keyPair,
        seqnoHeader(2),
        true,
    );
    val malformed = fixture.wallet.sendAnyExternal(createTruncatedAssignFlagXEnvelope(malformedReq));
    expect(malformed).toBeNotAccepted();
    expect(fixture.wallet.revision()).toEqual(Revision.Rev00_Initial);

    // A valid internal request loads old storage, migrates C4, and commits rev01 storage.
    val migrateReq = prepareSendMessagesI(
        fixture.keyPair,
        seqnoHeader(2),
        [makeTransferToSend(fixture.receiver.address, ton("0.001"))],
    );
    val migrateTrace = fixture
        .wallet
        .requestInternal(
            fixture.deployer.address,
            migrateReq,
            { value: ton("0.1") },
        );
    migrateTrace.giveName("migrate rev00 to rev01 via INTERNAL transfer");
    expect(migrateTrace).toHaveSuccessfulTx({
        from: fixture.deployer.address,
        to: fixture.wallet.address,
    });
    expect(migrateTrace).toHaveTx({
        from: fixture.wallet.address,
        to: fixture.receiver.address,
        value: ton("0.001"),
    });

    expect(fixture.wallet.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(fixture.wallet.flagX()).toEqual(false);
    expect(fixture.wallet.seqno()).toEqual(3);
}

get fun `test migration: invalid internal opcode rolls back before valid assign flagX`() {
    val fixture = deployRev00WalletWithActivity();

    // Simulate validators upgrading config to rev01 while the account C4 stays rev00.
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);

    // The getter surface is rev01, but persisted storage is still rev00.
    expect(fixture.wallet.revision()).toEqual(Revision.Rev00_Initial);
    expect(fixture.wallet.flagX()).toEqual(false);

    // A signed internal request with an unknown opcode reaches Storage.load() but rolls back on throw.
    val unknownBody = beginCell().storeUint(0xDEADBEEF, 32).endCell();
    val invalidTrace = fixture
        .wallet
        .sendAny(
            fixture.deployer.address,
            createRawSignedEnvelope(fixture.keyPair, unknownBody),
            { value: ton("0.1") },
        );
    invalidTrace.giveName("reject invalid internal opcode before migration commit");
    expect(invalidTrace).toHaveTx({
        from: fixture.deployer.address,
        to: fixture.wallet.address,
        exitCode: Errors.InvalidOpcode,
    });
    expect(fixture.wallet.revision()).toEqual(Revision.Rev00_Initial);

    // A valid AssignFlagX request migrates storage and applies the new rev01 field.
    val assignReq = prepareAssignFlagXE(
        fixture.keyPair,
        seqnoHeader(2),
        true,
    );
    val assign = fixture.wallet.requestExternal(assignReq);
    expect(assign).toBeAccepted();
    val assignTrace = assign.unwrap();
    assignTrace.giveName("migrate rev00 to rev01 via EXTERNAL assign flagX=true");
    expect(assignTrace).toHaveTx({ exitCode: 0 });

    expect(fixture.wallet.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(fixture.wallet.flagX()).toEqual(true);
    expect(fixture.wallet.seqno()).toEqual(3);
}

get fun `test migration: chained wallet message migrates both accounts`() {
    val deployer = testing.treasury("migration-chain-deployer");
    val key1 = crypto.generateKeyPair();
    val key2 = crypto.generateKeyPair();

    // Start with rev00 code in config and two independent rev00 wallet accounts.
    setWalletBytecodeInConfig(Revision.Rev00_Initial);
    val wallet1 = deployRev00Wallet(key1, deployer, "setup deploy rev00 WalletTg #1");
    val wallet2 = deployRev00Wallet(key2, deployer, "setup deploy rev00 WalletTg #2");

    // Top up both accounts while rev00 is active.
    val topUp1 = wallet1.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: ton("1"), bounce: false },
    );
    topUp1.giveName("setup top up rev00 WalletTg #1");
    expect(topUp1).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet1.address,
    });

    val topUp2 = wallet2.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: ton("1"), bounce: false },
    );
    topUp2.giveName("setup top up rev00 WalletTg #2");
    expect(topUp2).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet2.address,
    });

    // Wallet #1 sends an ordinary transfer to wallet #2 under rev00.
    val transferValue = ton("0.1");
    val transfer = wallet1.requestExternal(
        prepareSendMessagesE(
            key1,
            seqnoHeader(0),
            [makeTransferToSend(wallet2.address, transferValue)],
        ),
    );
    expect(transfer).toBeAccepted();
    val transferTrace = transfer.unwrap();
    transferTrace.giveName("setup rev00 WalletTg #1 transfer to #2");
    expect(transferTrace).toHaveTx({
        from: wallet1.address,
        to: wallet2.address,
        value: transferValue,
    });

    expect(wallet1.revision()).toEqual(Revision.Rev00_Initial);
    expect(wallet2.revision()).toEqual(Revision.Rev00_Initial);

    // Validators upgrade config to rev01, but both account C4 cells are still rev00.
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    expect(wallet1.revision()).toEqual(Revision.Rev00_Initial);
    expect(wallet2.revision()).toEqual(Revision.Rev00_Initial);

    // A plain top-up is accepted by the trampoline before the JMP, so it
    // increases balance without loading WalletTg or migrating storage.
    val balance1BeforeTopUp = testing.getAccountBalance(wallet1.address);
    val postUpgradeTopUp = wallet1.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: ton("1"), bounce: false },
    );
    postUpgradeTopUp.giveName("top up WalletTg #1 after rev01 config");
    expect(postUpgradeTopUp).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet1.address,
    });
    expect(testing.getAccountBalance(wallet1.address)).toBeGreater(balance1BeforeTopUp);
    expect(wallet1.revision()).toEqual(Revision.Rev00_Initial);

    // Wallet #1 sends a valid external request whose out action is a valid internal
    // AssignFlagX request for wallet #2. This migrates both accounts in one trace.
    val assignForWallet2 = prepareAssignFlagXI(
        key2,
        seqnoHeader(0),
        true,
    );
    val migrateBoth = wallet1.requestExternal(
        prepareSendMessagesE(
            key1,
            seqnoHeader(1),
            [makeSignedInternalRequestToSend(wallet2.address, ton("0.1"), assignForWallet2)],
        ),
    );
    expect(migrateBoth).toBeAccepted();
    val migrateBothTrace = migrateBoth.unwrap();
    migrateBothTrace.giveName("migrate two WalletTg accounts via chained AssignFlagX");
    expect(migrateBothTrace).toHaveSuccessfulTx({
        from: wallet1.address,
        to: wallet2.address,
    });

    expect(wallet1.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(wallet2.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(wallet1.flagX()).toEqual(false);
    expect(wallet2.flagX()).toEqual(true);
}

get fun `test migration: rev01 flagX survives rev02 Telegram user id migration`() {
    val deployer = testing.treasury("migration-rev02-deployer");
    val keyPair = crypto.generateKeyPair();

    // Start from rev00 storage and code; Telegram user id does not exist yet.
    setWalletBytecodeInConfig(Revision.Rev00_Initial);
    val wallet = deployRev00Wallet(
        keyPair,
        deployer,
        "setup deploy rev00 WalletTg for rev02 migration",
    );
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);
    expect(activeWalletCodeHasMethod("my_tg_user_id")).toBeFalse();

    // Rev01 code still does not know AssignTgUserId, and the failed request must not migrate C4.
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    expect(activeWalletCodeHasMethod("my_tg_user_id")).toBeFalse();
    val unknownTgSet = wallet.requestExternal(
        prepareAssignTgUserIdE(
            keyPair,
            seqnoHeader(0),
            MIGRATION_TG_USER_ID,
            MIGRATION_VALID_TG_SECRET_TAG,
        ),
    );
    expect(unknownTgSet).toBeNotAccepted();
    expect(unknownTgSet).toHaveExternalVmExitCode(Errors.InvalidOpcode);
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);
    expect(wallet.seqno()).toEqual(0);

    // A valid rev01 AssignFlagX request migrates from rev00 to rev01 and stores flagX=true.
    val assignFlagX = wallet.requestExternal(
        prepareAssignFlagXE(
            keyPair,
            seqnoHeader(0),
            true,
        ),
    );
    expect(assignFlagX).toBeAccepted();
    val flagXTrace = assignFlagX.unwrap();
    flagXTrace.giveName("migrate rev00 to rev01 via EXTERNAL assign flagX=true");
    expect(flagXTrace).toHaveTx({ exitCode: 0 });
    expect(wallet.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(wallet.flagX()).toEqual(true);
    expect(wallet.seqno()).toEqual(1);

    // Rev02 adds Telegram user id; setting it must preserve the rev01 flagX value.
    setWalletBytecodeInConfig(Revision.Rev02_TgUserId);
    expect(activeWalletCodeHasMethod("my_tg_user_id")).toBeTrue();
    val setTgUserId = wallet.requestExternal(
        prepareAssignTgUserIdE(
            keyPair,
            seqnoHeader(1),
            MIGRATION_TG_USER_ID,
            MIGRATION_VALID_TG_SECRET_TAG,
        ),
    );
    expect(setTgUserId).toBeAccepted();
    val tgUserIdTrace = setTgUserId.unwrap();
    tgUserIdTrace.giveName("migrate rev01 to rev02 via EXTERNAL assign Telegram user id");
    expect(tgUserIdTrace).toHaveTx({ exitCode: 0 });

    expect(wallet.revision()).toEqual(Revision.Rev02_TgUserId);
    expect(wallet.flagX()).toEqual(true);
    expect(wallet.myTgUserId()).toEqual(MIGRATION_TG_USER_ID);
}
