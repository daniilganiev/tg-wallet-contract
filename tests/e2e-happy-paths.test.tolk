import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@wrappers/WalletTrampoline.gen"
import "@wrappers/utils"
import "@contracts/WalletTg/messages"
import "@contracts/WalletTg/revisions"

/*
    This file benchmarks end-to-end happy paths as full transaction chains.
    It measures the wallet transaction plus all child delivery transactions.

    Contrast with e2e-send-gas.test.tolk, which intentionally executes only the
    single wallet transaction to measure WalletTg send path gas.
*/

const E2E_BENCH_KEY_SEED = 0x57560001
const E2E_BENCH_NEW_KEY_SEED = 0x57560002
const E2E_BENCH_NOW = 1000
const E2E_BENCH_VALID_UNTIL = 2000

const E2E_BENCH_DEPLOY_VALUE = ton("0.05")
const E2E_BENCH_TOP_UP_VALUE = ton("10")
const E2E_BENCH_SIGNED_INTERNAL_VALUE = ton("0.1")
const E2E_BENCH_TRANSFER_VALUE = ton("0.001")
const E2E_BENCH_TG_USER_ID = 580 as uint64
const E2E_BENCH_TG_SECRET_TAG = 0x1234567890 as uint128

struct E2EBenchFixture {
    wallet: WalletTrampoline
    deployer: Treasury
    receiver: Treasury
    keyPair: KeyPair
}

struct E2EBenchMigrationFixture {
    wallet1: WalletTrampoline
    wallet2: WalletTrampoline
    deployer: Treasury
    key1: KeyPair
    key2: KeyPair
}

fun e2eBenchKeyPair(): KeyPair {
    return crypto.seedToKeyPair(E2E_BENCH_KEY_SEED as uint256);
}

fun e2eBenchNewKeyPair(): KeyPair {
    return crypto.seedToKeyPair(E2E_BENCH_NEW_KEY_SEED as uint256);
}

fun e2eBenchRawTransferMessage(dest: address, value: coins): cell {
    return beginCell()
        .storeUint(0x10, 6)
        .storeAddress(dest)
        .storeCoins(value)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(createEmptyCell())
        .endCell();
}

fun e2eBenchToSend(dest: address, value: coins): MessageToSend {
    return MessageToSend {
        sendMode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
        messageCell: e2eBenchRawTransferMessage(dest, value),
    };
}

fun e2eBenchToSendList(count: int, dest: address): array<MessageToSend> {
    var msgArr = array<MessageToSend> [];
    repeat (count) {
        msgArr.push(e2eBenchToSend(dest, E2E_BENCH_TRANSFER_VALUE));
    }
    return msgArr;
}

fun deployE2EBenchFixture(): E2EBenchFixture {
    testing.setNow(E2E_BENCH_NOW);

    val keyPair = e2eBenchKeyPair();
    val deployer = testing.treasury("e2e-deployer");
    val receiver = testing.treasury("e2e-receiver");

    setWalletBytecodeInConfig();
    val storage = makeStorage(keyPair.publicKey);
    val wallet = WalletTrampoline.fromStorage(storage);

    val deployResult = wallet.deploy(
        deployer.address,
        { value: E2E_BENCH_DEPLOY_VALUE, bounce: false },
    );
    deployResult.giveName("e2e setup deploy WalletTg");
    expect(deployResult).toHaveSuccessfulDeploy({
        from: deployer.address,
        to: wallet.address,
    });

    val topUpResult = wallet.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: E2E_BENCH_TOP_UP_VALUE },
    );
    topUpResult.giveName("e2e setup top up WalletTg");
    expect(topUpResult).toHaveSuccessfulTx({ to: wallet.address });

    expect(wallet.revision()).toEqual(Revision.Rev02_TgUserId);
    expect(wallet.flagX()).toEqual(false);
    expect(wallet.myTgUserId()).toBeNull();

    return E2EBenchFixture { wallet, deployer, receiver, keyPair };
}

fun deployE2EBenchMigrationFixture(): E2EBenchMigrationFixture {
    testing.setNow(E2E_BENCH_NOW);
    setWalletBytecodeInConfig(Revision.Rev00_Initial);

    val deployer = testing.treasury("e2e-migration-deployer");
    val key1 = e2eBenchKeyPair();
    val key2 = e2eBenchNewKeyPair();
    val wallet1 = deployRev00Wallet(
        key1,
        deployer,
        "e2e migration setup deploy rev00 WalletTg #1",
        E2E_BENCH_DEPLOY_VALUE,
    );
    val wallet2 = deployRev00Wallet(
        key2,
        deployer,
        "e2e migration setup deploy rev00 WalletTg #2",
        E2E_BENCH_DEPLOY_VALUE,
    );

    val topUp1 = wallet1.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: E2E_BENCH_TOP_UP_VALUE, bounce: false },
    );
    topUp1.giveName("e2e migration setup top up rev00 WalletTg #1");
    expect(topUp1).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet1.address,
    });

    val topUp2 = wallet2.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: E2E_BENCH_TOP_UP_VALUE, bounce: false },
    );
    topUp2.giveName("e2e migration setup top up rev00 WalletTg #2");
    expect(topUp2).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet2.address,
    });

    expect(wallet1.revision()).toEqual(Revision.Rev00_Initial);
    expect(wallet2.revision()).toEqual(Revision.Rev00_Initial);

    return E2EBenchMigrationFixture { wallet1, wallet2, deployer, key1, key2 };
}

fun sendE2EBenchSignedExternal(
    fixture: E2EBenchFixture,
    msgArr: array<MessageToSend>,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val req = prepareSendMessagesE(
        fixture.keyPair,
        seqnoHeader(seqno, E2E_BENCH_VALID_UNTIL),
        msgArr,
    );
    val result = fixture.wallet.requestExternal(req);

    expect(result).toBeAccepted();
    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    return result.unwrap();
}

fun sendE2EBenchSignedInternal(
    fixture: E2EBenchFixture,
    msgArr: array<MessageToSend>,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val req = prepareSendMessagesI(
        fixture.keyPair,
        seqnoHeader(seqno, E2E_BENCH_VALID_UNTIL),
        msgArr,
    );
    val result = fixture
        .wallet
        .requestInternal(
            fixture.deployer.address,
            req,
            { value: E2E_BENCH_SIGNED_INTERNAL_VALUE },
        );

    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    return result;
}

fun sendE2EBenchChangeKeyExternal(
    fixture: E2EBenchFixture,
    newKey: KeyPair,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val req = prepareChangePublicKeyE(
        fixture.keyPair,
        seqnoHeader(seqno, E2E_BENCH_VALID_UNTIL),
        fixture.wallet.address,
        newKey,
    );
    val result = fixture.wallet.requestExternal(req);

    expect(result).toBeAccepted();
    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    expect(fixture.wallet.getPublicKey()).toEqual(newKey.publicKey);
    return result.unwrap();
}

fun sendE2EBenchChangeKeyInternal(
    fixture: E2EBenchFixture,
    newKey: KeyPair,
): SendResultList {
    val seqno = fixture.wallet.seqno();
    val req = prepareChangePublicKeyI(
        fixture.keyPair,
        seqnoHeader(seqno, E2E_BENCH_VALID_UNTIL),
        fixture.wallet.address,
        newKey,
    );
    val result = fixture
        .wallet
        .requestInternal(
            fixture.deployer.address,
            req,
            { value: E2E_BENCH_SIGNED_INTERNAL_VALUE },
        );

    expect(fixture.wallet.seqno()).toEqual(seqno + 1);
    expect(fixture.wallet.getPublicKey()).toEqual(newKey.publicKey);
    return result;
}

fun sendE2EBenchAssignTgUserIdExternal(
    wallet: WalletTrampoline,
    keyPair: KeyPair,
): SendResultList {
    val seqno = wallet.seqno();
    val result = wallet.requestExternal(
        prepareAssignTgUserIdE(
            keyPair,
            seqnoHeader(seqno, E2E_BENCH_VALID_UNTIL),
            E2E_BENCH_TG_USER_ID,
            E2E_BENCH_TG_SECRET_TAG,
        ),
    );

    expect(result).toBeAccepted();
    expect(wallet.seqno()).toEqual(seqno + 1);
    return result.unwrap();
}

fun assertFullChainSendResult(
    result: SendResultList,
    fixture: E2EBenchFixture,
    messageCount: int,
    receiverBalanceBefore: coins,
): void {
    expect(result.size()).toEqual(messageCount + 1);
    expect(result).toHaveTx({ exitCode: 0 });
    expect(result.at(0).outMessages.size()).toEqual(messageCount);

    var totalDeliveredValue: coins = 0;
    var totalReceiverFees: coins = 0;
    var i = 0;
    repeat (messageCount) {
        val deliveredTx = result.at(i + 1).tx.load();
        totalDeliveredValue += E2E_BENCH_TRANSFER_VALUE;
        totalReceiverFees += deliveredTx.totalFees.grams;
        i += 1;
    }
    val receiverBalanceAfter = testing.getAccountBalance(fixture.receiver.address);
    expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + totalDeliveredValue - totalReceiverFees);
}

get fun `test e2e full chain: EXTERNAL send 1 message`() {
    val fixture = deployE2EBenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val result = sendE2EBenchSignedExternal(
        fixture,
        e2eBenchToSendList(1, fixture.receiver.address),
    );
    result.giveName("e2e full-chain EXTERNAL send 1");

    assertFullChainSendResult(result, fixture, 1, receiverBalanceBefore);
}

get fun `test e2e full chain: INTERNAL send 1 message`() {
    val fixture = deployE2EBenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val result = sendE2EBenchSignedInternal(
        fixture,
        e2eBenchToSendList(1, fixture.receiver.address),
    );
    result.giveName("e2e full-chain INTERNAL send 1");

    assertFullChainSendResult(result, fixture, 1, receiverBalanceBefore);
}

get fun `test e2e full chain: EXTERNAL send 32 messages`() {
    val fixture = deployE2EBenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val result = sendE2EBenchSignedExternal(
        fixture,
        e2eBenchToSendList(32, fixture.receiver.address),
    );
    result.giveName("e2e full-chain EXTERNAL send 32");

    assertFullChainSendResult(result, fixture, 32, receiverBalanceBefore);
}

get fun `test e2e full chain: INTERNAL send 32 messages`() {
    val fixture = deployE2EBenchFixture();
    val receiverBalanceBefore = testing.getAccountBalance(fixture.receiver.address);

    val result = sendE2EBenchSignedInternal(
        fixture,
        e2eBenchToSendList(32, fixture.receiver.address),
    );
    result.giveName("e2e full-chain INTERNAL send 32");

    assertFullChainSendResult(result, fixture, 32, receiverBalanceBefore);
}

get fun `test e2e full chain: EXTERNAL change key`() {
    val fixture = deployE2EBenchFixture();
    val newKey = e2eBenchNewKeyPair();

    val result = sendE2EBenchChangeKeyExternal(fixture, newKey);
    result.giveName("e2e full-chain EXTERNAL change key");

    expect(result.size()).toEqual(1);
    expect(result).toHaveTx({ exitCode: 0 });
}

get fun `test e2e full chain: INTERNAL change key`() {
    val fixture = deployE2EBenchFixture();
    val newKey = e2eBenchNewKeyPair();

    val result = sendE2EBenchChangeKeyInternal(fixture, newKey);
    result.giveName("e2e full-chain INTERNAL change key");

    expect(result.size()).toEqual(1);
    expect(result).toHaveSuccessfulTx({
        from: fixture.deployer.address,
        to: fixture.wallet.address,
        exitCode: 0,
    });
}

get fun `test e2e full chain: MIGRATION chained AssignFlagX`() {
    val fixture = deployE2EBenchMigrationFixture();

    // Validators upgrade config to rev01 while both persisted account states are still rev00.
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    expect(fixture.wallet1.revision()).toEqual(Revision.Rev00_Initial);
    expect(fixture.wallet2.revision()).toEqual(Revision.Rev00_Initial);

    // Wallet #1 migrates, then sends a valid internal AssignFlagX request that migrates wallet #2.
    val assignForWallet2 = prepareAssignFlagXI(
        fixture.key2,
        seqnoHeader(0, E2E_BENCH_VALID_UNTIL),
        true,
    );
    val res = fixture
        .wallet1
        .requestExternal(
            prepareSendMessagesE(
                fixture.key1,
                seqnoHeader(0, E2E_BENCH_VALID_UNTIL),
                [
                    makeSignedInternalRequestToSend(
                        fixture.wallet2.address,
                        E2E_BENCH_SIGNED_INTERNAL_VALUE,
                        assignForWallet2,
                    ),
                ],
            ),
        );
    expect(res).toBeAccepted();

    val trace = res.unwrap();
    trace.giveName("e2e full-chain MIGRATION chained AssignFlagX");
    expect(trace.size()).toEqual(2);
    expect(trace).toHaveSuccessfulTx({
        from: fixture.wallet1.address,
        to: fixture.wallet2.address,
    });

    expect(fixture.wallet1.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(fixture.wallet2.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(fixture.wallet1.flagX()).toEqual(false);
    expect(fixture.wallet2.flagX()).toEqual(true);
}

get fun `test e2e full chain: MIGRATION rev01 to rev02 assign Telegram user id`() {
    testing.setNow(E2E_BENCH_NOW);
    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);

    val keyPair = e2eBenchKeyPair();
    val deployer = testing.treasury("e2e-rev02-migration-deployer");
    val wallet = deployRev01Wallet(
        keyPair,
        deployer,
        "e2e migration setup deploy rev01 WalletTg with flagX=true",
        true,
        E2E_BENCH_DEPLOY_VALUE,
    );

    val topUp = wallet.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: E2E_BENCH_TOP_UP_VALUE, bounce: false },
    );
    topUp.giveName("e2e migration setup top up rev01 WalletTg with flagX=true");
    expect(topUp).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet.address,
    });

    expect(wallet.revision()).toEqual(Revision.Rev01_AddFlagX);
    expect(wallet.flagX()).toEqual(true);

    setWalletBytecodeInConfig(Revision.Rev02_TgUserId);
    val result = sendE2EBenchAssignTgUserIdExternal(wallet, keyPair);
    result.giveName("e2e full-chain MIGRATION rev01 to rev02 assign Telegram user id");

    expect(result.size()).toEqual(1);
    expect(result).toHaveTx({ exitCode: 0 });
    expect(wallet.revision()).toEqual(Revision.Rev02_TgUserId);
    expect(wallet.myTgUserId()).toEqual(E2E_BENCH_TG_USER_ID);
    expect(wallet.flagX()).toEqual(true);
}
