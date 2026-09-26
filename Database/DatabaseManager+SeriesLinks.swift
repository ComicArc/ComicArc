import Foundation
import SQLite3

extension DatabaseManager {
    func renameSeries(oldName: String, publisher: String?, newName: String) {
        queue.sync {
            // Keep every other place a series is named by its raw string in sync too -- a custom
            // cover (series_covers), per-series reader settings (series_reader_prefs), and a
            // manual series ordering position (series_order) all previously went silently
            // orphaned under the old name after a rename, on top of series_links (already
            // handled). Wrapped in one transaction so a crash mid-rename can't leave these
            // pointing at different series names from each other.
            _ = inTransaction {
                if let pub = publisher, !pub.isEmpty, pub != "All" {
                    let ok1 = run("UPDATE comics SET series = ? WHERE series = ? AND publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok2 = run("UPDATE series_links SET parent_series = ? WHERE parent_series = ? AND parent_publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok3 = run("UPDATE series_links SET child_series = ? WHERE child_series = ? AND child_publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok4 = run("UPDATE series_covers SET series = ? WHERE series = ? AND publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok5 = run("UPDATE series_reader_prefs SET series = ? WHERE series = ? AND publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    let ok6 = run("UPDATE series_order SET series = ? WHERE series = ? AND publisher = ?",
                                   args: [newName, oldName, pub]) != -1
                    return ok1 && ok2 && ok3 && ok4 && ok5 && ok6
                } else {
                    let ok1 = run("UPDATE comics SET series = ? WHERE series = ?",
                                   args: [newName, oldName]) != -1
                    let ok2 = run("UPDATE series_links SET parent_series = ? WHERE parent_series = ?", args: [newName, oldName]) != -1
                    let ok3 = run("UPDATE series_links SET child_series = ? WHERE child_series = ?", args: [newName, oldName]) != -1
                    let ok4 = run("UPDATE series_covers SET series = ? WHERE series = ?", args: [newName, oldName]) != -1
                    let ok5 = run("UPDATE series_reader_prefs SET series = ? WHERE series = ?", args: [newName, oldName]) != -1
                    let ok6 = run("UPDATE series_order SET series = ? WHERE series = ?", args: [newName, oldName]) != -1
                    return ok1 && ok2 && ok3 && ok4 && ok5 && ok6
                }
            }
        }
    }

    func seriesNameCollides(oldName: String, publisher: String?, newName: String) -> Bool {
        guard newName != oldName else { return false }
        return queue.sync {
            if let pub = publisher, !pub.isEmpty, pub != "All" {
                return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ? AND publisher = ?",
                                  args: [newName, pub]) > 0
            }
            return scalarInt("SELECT COUNT(*) FROM comics WHERE series = ?", args: [newName]) > 0
        }
    }

}
