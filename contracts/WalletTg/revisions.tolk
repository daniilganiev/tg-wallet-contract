/// Every time the contract logic is updated,
/// we append a new revision and provide a new storage migration.
/// Read `MIGRATION.md`.
enum Revision : uint8 {
    Rev00_Initial = 0,
    Rev01_AddFlagX = 1,
    Rev02_TgUserId = 2,
}

const LAST_REVISION = Revision.Rev02_TgUserId
