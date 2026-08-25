import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@wrappers/WalletTrampoline.gen"
import "@wrappers/utils"
import "@contracts/WalletTg/revisions"

/*
    This file checks the rev01 flagX request and getter on freshly deployed wallets.
*/

get fun `test flagX: new trampoline wallet assigns flagX`() {
    val keyPair = crypto.generateKeyPair();
    val (wallet, _) = deployWalletWithKey(keyPair);

    expect(wallet.revision()).toEqual(LAST_REVISION);
    expect(wallet.flagX()).toEqual(false);
    expect(wallet.seqno()).toEqual(0);

    val req = prepareAssignFlagXE(
        keyPair,
        seqnoHeader(0),
        true,
    );
    val result = wallet.requestExternal(req);
    expect(result).toBeAccepted();
    val assignTrace = result.unwrap();
    assignTrace.giveName("EXTERNAL assign flagX=true");
    expect(assignTrace).toHaveTx({ exitCode: 0 });

    expect(wallet.flagX()).toEqual(true);
    expect(wallet.seqno()).toEqual(1);
    expect(wallet.revision()).toEqual(LAST_REVISION);
}

get fun `test flagX: getter handles rev00 storage after rev01 config upgrade`() {
    val keyPair = crypto.generateKeyPair();
    val deployer = testing.treasury("flagx-migration-deployer");

    setWalletBytecodeInConfig(Revision.Rev00_Initial);
    val wallet = deployRev00Wallet(keyPair, deployer, "setup deploy rev00 WalletTg for flagX getter");
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);

    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);
    expect(wallet.flagX()).toEqual(false); // does not fail due to tmp c4 migration in Storage.load
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);
}

get fun `test flagX: old client deploys rev00 storage while config is rev01`() {
    val keyPair = crypto.generateKeyPair();
    val deployer = testing.treasury("flagx-old-client-deployer");
    val receiver = testing.treasury("flagx-old-client-receiver");

    setWalletBytecodeInConfig(Revision.Rev01_AddFlagX);
    val wallet = deployRev00Wallet(keyPair, deployer, "setup old client deploys rev00 storage under rev01 config");

    val topUp = wallet.sendAny(
        deployer.address,
        createEmptyCell(),
        { value: ton("1"), bounce: false },
    );
    topUp.giveName("top up old-client rev00 storage wallet under rev01 config");
    expect(topUp).toHaveSuccessfulTx({
        from: deployer.address,
        to: wallet.address,
    });

    expect(wallet.flagX()).toEqual(false);
    expect(wallet.revision()).toEqual(Revision.Rev00_Initial);

    val req = prepareSendMessagesE(
        keyPair,
        seqnoHeader(0),
        [makeTransferToSend(receiver.address, ton("0.001"))],
    );
    val result = wallet.requestExternal(req);
    expect(result).toBeAccepted();
    val trace = result.unwrap();
    trace.giveName("old-client rev00 storage migrates on first signed request");
    expect(trace).toHaveTx({
        from: wallet.address,
        to: receiver.address,
        value: ton("0.001"),
    });

    expect(wallet.flagX()).toEqual(false);
    expect(wallet.revision()).toEqual(Revision.Rev01_AddFlagX);
}
