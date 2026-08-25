import "@stdlib/tvm-lowlevel"
import "storage"

fun convertOldStorageToLatest(): Storage {
    val old = lazy UnionOfOldStorages.fromCell(contract.getData());
    return match (old) {
        OldStorage_00 => Storage {
            seqno: old.seqno,
            subwalletId: old.subwalletId,
            publicKey: old.publicKey,
        },
        else => {
            // can happen only if c4 is corrupted;
            // may be emulated by tests, can't happen in production
            throw VmExitCode.OpcodeDoesNotMatch;
        }
    }
}

/// After a bytecode upgrade by validator voting, c4 contains old storage.
/// Its "c4 revision" is determined by the 0xXX prefix of c4.
/// Here we run the migration from the current c4 revision to LAST (from OldStorage_XX to Storage).
/// Runs at most once: it always does `contract.setData`.
@noinline
fun runMigrationAndUpdateC4(): void {
    val new = convertOldStorageToLatest();
    contract.setData(new.toCell());
}
