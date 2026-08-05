import Foundation
import SQLite3

extension DatabaseManager {
    struct SeriesLink {
        let id: Int64
        let parentPublisher: String; let parentSeries: String; let parentVolume: String?
        let childPublisher: String; let childSeries: String; let childVolume: String?
        let sequenceOrder: Int
        let source: String
    }

    func seriesLinks() -> [SeriesLink] {
        queue.sync {
            rows("""
                SELECT id, parent_publisher, parent_series, parent_volume,
                       child_publisher, child_series, child_volume, sequence_order, source
                FROM series_links ORDER BY sequence_order
                """) { s in
                SeriesLink(id: colInt64(s, 0), parentPublisher: colText(s, 1) ?? "", parentSeries: colText(s, 2) ?? "",
                           parentVolume: colText(s, 3), childPublisher: colText(s, 4) ?? "", childSeries: colText(s, 5) ?? "",
                           childVolume: colText(s, 6), sequenceOrder: colInt(s, 7), source: colText(s, 8) ?? "manual")
            }
        }
    }

    /// Combines publisher+series+volume into one key with volume-aware equality -- NULL and ""
    /// (no volume tag at all) are treated identically, matching the same COALESCE(...,'')
    /// convention used for `comics.volume` everywhere else (groupKey, series_group, etc.).
    static func seriesVolumeKey(publisher: String, series: String, volume: String?) -> String {
        "\(publisher):\(series):\(volume?.isEmpty == false ? volume! : "")"
    }

    @discardableResult
    func addSeriesLink(parentPublisher: String, parentSeries: String, parentVolume: String? = nil,
                       childPublisher: String, childSeries: String, childVolume: String? = nil,
                       source: String = "manual") -> Bool {
        queue.sync {
            let nextSeq = scalarInt("SELECT COALESCE(MAX(sequence_order), 0) + 1 FROM series_links")
            let before = scalarInt("""
                SELECT COUNT(*) FROM series_links
                WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = COALESCE(NULLIF(?,''),'')
                """, args: [childPublisher, childSeries, childVolume])
            guard before == 0 else { return false }

            let childKey = Self.seriesVolumeKey(publisher: childPublisher, series: childSeries, volume: childVolume)
            var ancestor: String? = Self.seriesVolumeKey(publisher: parentPublisher, series: parentSeries, volume: parentVolume)
            var hops = 0
            while let current = ancestor, hops < 100 {
                if current == childKey { return false }
                ancestor = scalarText("""
                    SELECT parent_publisher || ':' || parent_series || ':' || COALESCE(NULLIF(parent_volume,''),'')
                    FROM series_links
                    WHERE child_publisher || ':' || child_series || ':' || COALESCE(NULLIF(child_volume,''),'') = ?
                    """, args: [current]
                )
                hops += 1
            }

            _ = run("""
                INSERT INTO series_links (parent_publisher, parent_series, parent_volume,
                                           child_publisher, child_series, child_volume, sequence_order, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, args: [parentPublisher, parentSeries, parentVolume, childPublisher, childSeries, childVolume, nextSeq, source])
            return true
        }
    }

    func removeSeriesLink(childPublisher: String, childSeries: String, childVolume: String? = nil) {
        queue.sync {
            _ = run("""
                DELETE FROM series_links
                WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = COALESCE(NULLIF(?,''),'')
                """, args: [childPublisher, childSeries, childVolume])
        }
    }

    func seriesLinkCycles() -> [[String]] {
        queue.sync { _seriesLinkCyclesUnlocked() }
    }

    func breakSeriesLinkCycles() {
        queue.sync {
            for cycle in _seriesLinkCyclesUnlocked() {
                let members = Set(cycle)
                guard let toBreak: (child: String, seq: Int) = rows(
                    """
                    SELECT child_publisher || ':' || child_series || ':' || COALESCE(NULLIF(child_volume,''),''), sequence_order
                    FROM series_links ORDER BY sequence_order DESC
                    """,
                    map: { s in (colText(s, 0) ?? "", colInt(s, 1)) }
                ).first(where: { members.contains($0.child) }) else { continue }
                let parts = toBreak.child.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                _ = run("""
                    DELETE FROM series_links
                    WHERE child_publisher = ? AND child_series = ? AND COALESCE(NULLIF(child_volume,''),'') = ?
                    """, args: [parts[0], parts[1], parts[2]])
            }
        }
    }

    func _seriesLinkCyclesUnlocked() -> [[String]] {
        let links: [(parentKey: String, childKey: String)] = rows("""
            SELECT parent_publisher, parent_series, COALESCE(NULLIF(parent_volume,''),''),
                   child_publisher, child_series, COALESCE(NULLIF(child_volume,''),'')
            FROM series_links
            """
        ) { s in
            ("\(colText(s, 0) ?? ""):\(colText(s, 1) ?? ""):\(colText(s, 2) ?? "")",
             "\(colText(s, 3) ?? ""):\(colText(s, 4) ?? ""):\(colText(s, 5) ?? "")")
        }
        return SeriesContinuity.findCycles(links: links)
    }

    func allSeriesNames() -> [(publisher: String, series: String)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series FROM comics
                WHERE deleted_at IS NULL ORDER BY series
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General") }
        }
    }

    /// Distinct (publisher, series, volume) triples -- unlike `allSeriesNames()`, this tells two
    /// differently-volumed runs of the same Series name apart (e.g. Amazing Spider-Man Vol. 1 vs
    /// Vol. 2), which is what the series-link picker needs to offer them as separate candidates.
    func allSeriesVolumes() -> [(publisher: String, series: String, volume: String?)] {
        queue.sync {
            rows("""
                SELECT DISTINCT publisher, series, volume FROM comics
                WHERE deleted_at IS NULL ORDER BY series, volume
                """) { s in (colText(s, 0) ?? "Unknown", colText(s, 1) ?? "General", colText(s, 2)) }
        }
    }

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
