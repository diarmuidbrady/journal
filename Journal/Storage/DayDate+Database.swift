import Foundation
import GRDB

extension DayDate: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { string.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DayDate? {
        String.fromDatabaseValue(dbValue).flatMap(DayDate.init(string:))
    }
}
