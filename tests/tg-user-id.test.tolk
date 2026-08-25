import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/testing/expect"
import "@wrappers/WalletTrampoline.gen"
import "@wrappers/utils"
import "@contracts/WalletTg/errors"
import "@contracts/WalletTg/revisions"

/*
    This file checks the rev02 Telegram user id request and getter.
*/

const VALID_TG_SECRET_TAG = 0x1234567890 as uint128
const INVALID_TG_SECRET_TAG = 0x9988776655 as uint128
const TG_USER_ID = 580 as uint64

get fun `test tg user id: new trampoline wallet assigns Telegram user id`() {
    val keyPair = crypto.generateKeyPair();
    val (wallet, _) = deployWalletWithKey(keyPair);

    expect(wallet.revision()).toEqual(LAST_REVISION);
    expect(wallet.myTgUserId()).toBeNull();
    expect(wallet.flagX()).toEqual(false);
    expect(wallet.seqno()).toEqual(0);

    // A wrong Telegram secret must fail before seqno or tg_user_id changes.
    val invalidSet = wallet.requestExternal(
        prepareAssignTgUserIdE(
            keyPair,
            seqnoHeader(0),
            TG_USER_ID,
            INVALID_TG_SECRET_TAG,
        ),
    );
    expect(invalidSet).toBeNotAccepted();
    expect(invalidSet).toHaveExternalVmExitCode(Errors.TgSecretKeyInvalid);
    expect(wallet.seqno()).toEqual(0);
    expect(wallet.myTgUserId()).toBeNull();

    // A valid request stores Telegram user_id and bumps seqno.
    val validSet = wallet.requestExternal(
        prepareAssignTgUserIdE(
            keyPair,
            seqnoHeader(0),
            TG_USER_ID,
            VALID_TG_SECRET_TAG,
        ),
    );
    expect(validSet).toBeAccepted();
    val setTrace = validSet.unwrap();
    setTrace.giveName("EXTERNAL assign Telegram user id");
    expect(setTrace).toHaveTx({ exitCode: 0 });
    expect(wallet.seqno()).toEqual(1);
    expect(wallet.myTgUserId()).toEqual(TG_USER_ID);
    expect(wallet.flagX()).toEqual(false);

    // Updating flagX must not disturb the stored Telegram user_id.
    val assignFlagX = wallet.requestExternal(
        prepareAssignFlagXE(
            keyPair,
            seqnoHeader(1),
            true,
        ),
    );
    expect(assignFlagX).toBeAccepted();
    val flagXTrace = assignFlagX.unwrap();
    flagXTrace.giveName("EXTERNAL assign flagX=true after Telegram user id");
    expect(flagXTrace).toHaveTx({ exitCode: 0 });
    expect(wallet.seqno()).toEqual(2);
    expect(wallet.flagX()).toEqual(true);
    expect(wallet.myTgUserId()).toEqual(TG_USER_ID);
}
