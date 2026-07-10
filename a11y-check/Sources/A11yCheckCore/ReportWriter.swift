/*
   Copyright 2026 CVS Health and/or one of its affiliates

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 */

import Foundation

/// Path conventions and legacy-file migration for the `--report` artifact folder.
///
/// Layout: `<report-root>/swift/` where `<report-root>` defaults to `.a11y`
/// inside the analyzed directory. The `swift/` subfolder namespaces artifacts
/// so the layout composes with a multi-platform `.a11y/` convention.
public enum ReportLayout {

    /// Default report root folder name, created inside the analyzed directory.
    public static let defaultRootName = ".a11y"

    /// Platform namespace subfolder under the report root.
    public static let platformDirName = "swift"

    /// Trend history file name inside the platform folder (relocated `.a11y-scores.json`).
    public static let scoresFileName = "scores.json"

    /// Baseline file name inside the platform folder (relocated `.a11y-baseline.json`).
    public static let baselineFileName = "baseline.json"

    /// Legacy top-level trend history file name (pre-`--report`).
    public static let legacyScoresFileName = ".a11y-scores.json"

    /// The platform artifact directory for a given report root.
    public static func platformDirectory(reportRoot: String) -> String {
        (reportRoot as NSString).appendingPathComponent(platformDirName)
    }

    /// Path to the trend history file inside the platform folder.
    public static func scoresPath(platformDir: String) -> String {
        (platformDir as NSString).appendingPathComponent(scoresFileName)
    }

    /// Path to the baseline file inside the platform folder.
    public static func baselinePath(platformDir: String) -> String {
        (platformDir as NSString).appendingPathComponent(baselineFileName)
    }

    /// Seed `<platformDir>/scores.json` from a legacy top-level `.a11y-scores.json`
    /// when the folder form does not exist yet. The legacy file is left in place
    /// (copy, not move) so pre-`--report` workflows keep working.
    /// Returns true if a migration copy was performed.
    @discardableResult
    public static func migrateLegacyScores(analysisRoot: String, platformDir: String) throws -> Bool {
        let fm = FileManager.default
        let newPath = scoresPath(platformDir: platformDir)
        guard !fm.fileExists(atPath: newPath) else { return false }
        let legacyPath = (analysisRoot as NSString).appendingPathComponent(legacyScoresFileName)
        guard fm.fileExists(atPath: legacyPath) else { return false }
        try fm.createDirectory(atPath: platformDir, withIntermediateDirectories: true)
        try fm.copyItem(atPath: legacyPath, toPath: newPath)
        return true
    }
}

/// A stably-ordered, timestamp-free snapshot of the current findings.
/// This file is the run-over-run tracking anchor: identical scans of an
/// unchanged tree must produce byte-identical snapshots.
public struct FindingsSnapshot: Codable, Sendable {

    public static let currentSchemaVersion = 1

    public struct Finding: Codable, Sendable {
        public let ruleID: String
        /// Path relative to the analyzed root when possible (keeps fingerprints
        /// stable across checkouts in different workspace directories).
        public let filePath: String
        public let line: Int
        public let column: Int
        public let severity: String
        public let impact: String
        public let message: String
        public let wcagCriteria: [String]

        /// Fingerprint identifying this finding ignoring line numbers,
        /// matching the `Baseline` / `--diff-report` fingerprint shape.
        public var fingerprint: String {
            "\(ruleID)|\(filePath)|\(message)"
        }
    }

    public let schemaVersion: Int
    public let findings: [Finding]

    /// Build a snapshot from diagnostics, relativizing paths against `analysisRoot`
    /// and sorting deterministically by (filePath, line, column, ruleID, message).
    public static func from(diagnostics: [A11yDiagnostic], analysisRoot: String) -> FindingsSnapshot {
        let root = (analysisRoot as NSString).standardizingPath
        let findings = diagnostics.map { diag -> Finding in
            Finding(
                ruleID: diag.ruleID,
                filePath: relativize(diag.filePath, against: root),
                line: diag.line,
                column: diag.column,
                severity: diag.severity.rawValue,
                impact: diag.impact.rawValue,
                message: diag.message,
                wcagCriteria: diag.wcagCriteria
            )
        }.sorted { a, b in
            if a.filePath != b.filePath { return a.filePath < b.filePath }
            if a.line != b.line { return a.line < b.line }
            if a.column != b.column { return a.column < b.column }
            if a.ruleID != b.ruleID { return a.ruleID < b.ruleID }
            return a.message < b.message
        }
        return FindingsSnapshot(schemaVersion: currentSchemaVersion, findings: findings)
    }

    private static func relativize(_ path: String, against root: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.hasPrefix(root + "/") {
            return String(standardized.dropFirst(root.count + 1))
        }
        return standardized
    }
}

/// The `summary.json` run manifest: schema version, tool/build/git metadata,
/// score rollups, and the new/fixed/persisting delta vs the previous snapshot.
/// All volatile fields (timestamp, git SHA) live here, never in `findings.json`.
public struct RunSummary: Codable, Sendable {

    public static let currentSchemaVersion = 1

    public struct Tool: Codable, Sendable {
        public let name: String
        public let version: String
        public let buildCommit: String
        public let buildDate: String
    }

    public struct Git: Codable, Sendable {
        public let commit: String?
    }

    public struct ScoreInfo: Codable, Sendable {
        public let score: Double
        public let grade: String
    }

    public struct Counts: Codable, Sendable {
        public let errors: Int
        public let warnings: Int
        public let info: Int
        public let total: Int
        public let byRule: [String: Int]
        public let byWCAGCriterion: [String: Int]
    }

    public struct Criteria: Codable, Sendable {
        public let passed: Int
        public let failed: Int
        public let notChecked: Int
    }

    public struct DeltaCounts: Codable, Sendable {
        public let new: Int
        public let fixed: Int
        public let persisting: Int
    }

    public let schemaVersion: Int
    public let generatedAt: String
    public let tool: Tool
    public let git: Git
    public let score: ScoreInfo
    public let counts: Counts
    public let criteria: Criteria
    public let filesAnalyzed: Int
    /// nil on the first run (no previous findings.json to diff against).
    public let delta: DeltaCounts?
}

/// Writes the full `--report` artifact set into a report folder in one pass.
///
/// Reuses the existing formatters unchanged — `report.sarif` / `report.json` /
/// `report.html` are byte-equivalent to the corresponding `--format` stdout
/// output for the same inputs. Adds two new artifacts: `findings.json`
/// (deterministic tracking snapshot) and `summary.json` (run manifest).
public struct ReportWriter {

    public struct ToolInfo: Sendable {
        public let name: String
        public let version: String
        public let buildCommit: String
        public let buildDate: String

        public init(name: String, version: String, buildCommit: String, buildDate: String) {
            self.name = name
            self.version = version
            self.buildCommit = buildCommit
            self.buildDate = buildDate
        }
    }

    public struct Result: Sendable {
        /// File names written, in write order.
        public let artifacts: [String]
        /// Delta vs the previous findings.json; nil on first run.
        public let delta: RunSummary.DeltaCounts?
        /// Non-fatal problems encountered (e.g. unreadable previous snapshot).
        public let warnings: [String]
    }

    public static let sarifFileName = "report.sarif"
    public static let jsonFileName = "report.json"
    public static let htmlFileName = "report.html"
    public static let findingsFileName = "findings.json"
    public static let summaryFileName = "summary.json"
    public static let badgeFileName = "badge.svg"

    public init() {}

    /// Write all artifacts into `outputDirectory` (created if needed).
    /// `diagnostics` must be the finalized, already-filtered set the run would
    /// otherwise output — this method performs no filtering of its own.
    public func write(
        diagnostics: [A11yDiagnostic],
        score: A11yScore,
        allRules: [any A11yRule],
        enabledRules: [any A11yRule],
        trendEntries: [TrendTracker.Entry],
        toolInfo: ToolInfo,
        analysisRoot: String,
        outputDirectory: String
    ) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        var warnings: [String] = []

        // Snapshot + delta: read the previous findings.json before overwriting it.
        let snapshot = FindingsSnapshot.from(diagnostics: diagnostics, analysisRoot: analysisRoot)
        let findingsPath = path(outputDirectory, Self.findingsFileName)
        var delta: RunSummary.DeltaCounts? = nil
        if fm.fileExists(atPath: findingsPath) {
            if let data = fm.contents(atPath: findingsPath),
               let previous = try? JSONDecoder().decode(FindingsSnapshot.self, from: data) {
                delta = computeDelta(previous: previous, current: snapshot)
            } else {
                warnings.append("previous \(Self.findingsFileName) could not be read; delta skipped for this run")
            }
        }

        // Format artifacts with the exact same calls the CLI makes for --format output.
        let sarif = try SARIFFormatter().format(diagnostics, rules: enabledRules, score: score)
        let json = try JSONFormatter().format(diagnostics, score: score, trendEntries: trendEntries)
        let html = HTMLFormatter().format(diagnostics, allRules: allRules, score: score, trendEntries: trendEntries)
        let badge = BadgeGenerator().generate(score: score)

        let summary = RunSummary(
            schemaVersion: RunSummary.currentSchemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            tool: RunSummary.Tool(
                name: toolInfo.name,
                version: toolInfo.version,
                buildCommit: toolInfo.buildCommit,
                buildDate: toolInfo.buildDate
            ),
            git: RunSummary.Git(commit: gitCommit(in: analysisRoot)),
            score: RunSummary.ScoreInfo(score: score.score, grade: score.grade),
            counts: makeCounts(diagnostics: diagnostics, score: score),
            criteria: RunSummary.Criteria(
                passed: score.criteriaPassed,
                failed: score.criteriaFailed,
                notChecked: score.criteriaNotChecked
            ),
            filesAnalyzed: score.filesAnalyzed,
            delta: delta
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let findingsData = try encoder.encode(snapshot)
        let summaryData = try encoder.encode(summary)

        // stdout output gains a trailing newline from print(); match it so
        // artifacts are byte-equivalent to the corresponding --format output.
        try writeAtomic(sarif + "\n", to: path(outputDirectory, Self.sarifFileName))
        try writeAtomic(json + "\n", to: path(outputDirectory, Self.jsonFileName))
        try writeAtomic(html + "\n", to: path(outputDirectory, Self.htmlFileName))
        try writeAtomic(String(data: findingsData, encoding: .utf8)! + "\n", to: findingsPath)
        try writeAtomic(String(data: summaryData, encoding: .utf8)! + "\n", to: path(outputDirectory, Self.summaryFileName))
        try writeAtomic(badge + "\n", to: path(outputDirectory, Self.badgeFileName))

        return Result(
            artifacts: [
                Self.sarifFileName, Self.jsonFileName, Self.htmlFileName,
                Self.findingsFileName, Self.summaryFileName, Self.badgeFileName,
            ],
            delta: delta,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private func path(_ directory: String, _ fileName: String) -> String {
        (directory as NSString).appendingPathComponent(fileName)
    }

    private func writeAtomic(_ contents: String, to filePath: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    private func computeDelta(previous: FindingsSnapshot, current: FindingsSnapshot) -> RunSummary.DeltaCounts {
        let previousFingerprints = Set(previous.findings.map(\.fingerprint))
        let currentFingerprints = Set(current.findings.map(\.fingerprint))
        return RunSummary.DeltaCounts(
            new: currentFingerprints.subtracting(previousFingerprints).count,
            fixed: previousFingerprints.subtracting(currentFingerprints).count,
            persisting: currentFingerprints.intersection(previousFingerprints).count
        )
    }

    private func makeCounts(diagnostics: [A11yDiagnostic], score: A11yScore) -> RunSummary.Counts {
        var byRule: [String: Int] = [:]
        var byCriterion: [String: Int] = [:]
        for diag in diagnostics {
            byRule[diag.ruleID, default: 0] += 1
            for criterion in diag.wcagCriteria {
                byCriterion[criterion, default: 0] += 1
            }
        }
        return RunSummary.Counts(
            errors: score.totalErrors,
            warnings: score.totalWarnings,
            info: score.totalInfo,
            total: diagnostics.count,
            byRule: byRule,
            byWCAGCriterion: byCriterion
        )
    }

    private func gitCommit(in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (sha?.isEmpty == false) ? sha : nil
        } catch {
            return nil
        }
    }
}
