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

import XCTest
@testable import A11yCheckCore

final class ReportWriterTests: XCTestCase {

    private var tempRoot: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("a11y-report-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempRoot = dir
    }

    override func tearDownWithError() throws {
        if let tempRoot = tempRoot {
            try? FileManager.default.removeItem(atPath: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var platformDir: String {
        ReportLayout.platformDirectory(
            reportRoot: (tempRoot as NSString).appendingPathComponent(ReportLayout.defaultRootName)
        )
    }

    private func makeDiagnostic(
        ruleID: String = "image-missing-label",
        file: String = "Views/MyView.swift",
        line: Int = 10,
        column: Int = 5,
        severity: A11ySeverity = .error,
        message: String = "Image missing .accessibilityLabel"
    ) -> A11yDiagnostic {
        A11yDiagnostic(
            ruleID: ruleID,
            severity: severity,
            impact: .serious,
            message: message,
            filePath: (tempRoot as NSString).appendingPathComponent(file),
            line: line,
            column: column,
            wcagCriteria: ["1.1.1"]
        )
    }

    private func makeScore(diagnostics: [A11yDiagnostic], registry: RuleRegistry) -> A11yScore {
        ScoreCalculator().calculate(
            diagnostics: diagnostics,
            rules: registry.enabledRules,
            filePaths: Array(Set(diagnostics.map(\.filePath)))
        )
    }

    private let toolInfo = ReportWriter.ToolInfo(
        name: "a11y-check", version: "0.0.0-test", buildCommit: "abc1234", buildDate: "2026-01-01"
    )

    @discardableResult
    private func writeReport(
        diagnostics: [A11yDiagnostic],
        to directory: String? = nil,
        trendEntries: [TrendTracker.Entry] = []
    ) throws -> ReportWriter.Result {
        let registry = RuleRegistry()
        let score = makeScore(diagnostics: diagnostics, registry: registry)
        return try ReportWriter().write(
            diagnostics: diagnostics,
            score: score,
            allRules: registry.rules,
            enabledRules: registry.enabledRules,
            trendEntries: trendEntries,
            toolInfo: toolInfo,
            analysisRoot: tempRoot,
            outputDirectory: directory ?? platformDir
        )
    }

    private func artifactData(_ fileName: String, in directory: String? = nil) throws -> Data {
        let path = ((directory ?? platformDir) as NSString).appendingPathComponent(fileName)
        return try XCTUnwrap(FileManager.default.contents(atPath: path), "missing artifact \(fileName)")
    }

    private func artifactJSON(_ fileName: String, in directory: String? = nil) throws -> [String: Any] {
        let data = try artifactData(fileName, in: directory)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(fileName) is not a JSON object"
        )
    }

    // MARK: - Artifact creation & parseability

    func testWrite_createsFolderAndAllArtifacts() throws {
        let diags = [makeDiagnostic()]
        let result = try writeReport(diagnostics: diags)

        let expected = [
            "report.sarif", "report.json", "report.html",
            "findings.json", "summary.json", "badge.svg",
        ]
        XCTAssertEqual(result.artifacts, expected)
        for name in expected {
            let path = (platformDir as NSString).appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "expected \(name) to exist")
        }
    }

    func testWrite_artifactsAreParseable() throws {
        try writeReport(diagnostics: [makeDiagnostic()])

        let sarif = try artifactJSON("report.sarif")
        XCTAssertEqual(sarif["version"] as? String, "2.1.0")
        XCTAssertNotNil(sarif["runs"] as? [Any])

        let json = try artifactJSON("report.json")
        XCTAssertNotNil(json["diagnostics"] as? [Any])
        XCTAssertNotNil(json["score"] as? [String: Any])

        let findings = try artifactJSON("findings.json")
        XCTAssertEqual(findings["schemaVersion"] as? Int, FindingsSnapshot.currentSchemaVersion)
        XCTAssertEqual((findings["findings"] as? [Any])?.count, 1)

        let summary = try artifactJSON("summary.json")
        XCTAssertEqual(summary["schemaVersion"] as? Int, RunSummary.currentSchemaVersion)

        let html = String(decoding: try artifactData("report.html"), as: UTF8.self)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("</html>"))

        let badge = String(decoding: try artifactData("badge.svg"), as: UTF8.self)
        XCTAssertTrue(badge.contains("<svg"))
    }

    func testWrite_emptyDiagnosticsStillWritesAllArtifacts() throws {
        let result = try writeReport(diagnostics: [])
        XCTAssertEqual(result.artifacts.count, 6)
        let findings = try artifactJSON("findings.json")
        XCTAssertEqual((findings["findings"] as? [Any])?.count, 0)
    }

    // MARK: - Byte-equivalence with --format stdout output

    func testReportJSON_byteEquivalentToJSONFormatterOutput() throws {
        let diags = [makeDiagnostic(), makeDiagnostic(ruleID: "fixed-font-size", line: 20, severity: .warning, message: "Fixed font size")]
        let registry = RuleRegistry()
        let score = makeScore(diagnostics: diags, registry: registry)
        try writeReport(diagnostics: diags)

        let expected = try JSONFormatter().format(diags, score: score, trendEntries: []) + "\n"
        let actual = String(decoding: try artifactData("report.json"), as: UTF8.self)
        XCTAssertEqual(actual, expected)
    }

    func testReportSARIF_byteEquivalentToSARIFFormatterOutput() throws {
        let diags = [makeDiagnostic()]
        let registry = RuleRegistry()
        let score = makeScore(diagnostics: diags, registry: registry)
        try writeReport(diagnostics: diags)

        let expected = try SARIFFormatter().format(diags, rules: registry.enabledRules, score: score) + "\n"
        let actual = String(decoding: try artifactData("report.sarif"), as: UTF8.self)
        XCTAssertEqual(actual, expected)
    }

    // MARK: - findings.json determinism

    func testFindings_identicalRunsProduceIdenticalBytes() throws {
        let diags = [
            makeDiagnostic(),
            makeDiagnostic(ruleID: "fixed-font-size", file: "Views/Other.swift", line: 3, severity: .warning, message: "Fixed font size"),
        ]
        try writeReport(diagnostics: diags)
        let first = try artifactData("findings.json")

        // Second run in the same folder (delta present in summary must not leak into findings)
        try writeReport(diagnostics: diags)
        let second = try artifactData("findings.json")
        XCTAssertEqual(first, second, "findings.json must be byte-identical across identical runs")

        // And in a fresh folder
        let otherDir = (tempRoot as NSString).appendingPathComponent("other-report/swift")
        try writeReport(diagnostics: diags, to: otherDir)
        let third = try artifactData("findings.json", in: otherDir)
        XCTAssertEqual(first, third)
    }

    func testFindings_orderIndependentOfInputOrder() throws {
        let diags = [
            makeDiagnostic(ruleID: "b-rule", file: "B.swift", line: 2, message: "bbb"),
            makeDiagnostic(ruleID: "a-rule", file: "A.swift", line: 9, message: "aaa"),
            makeDiagnostic(ruleID: "a-rule", file: "A.swift", line: 1, message: "aaa"),
        ]
        try writeReport(diagnostics: diags)
        let forward = try artifactData("findings.json")

        let otherDir = (tempRoot as NSString).appendingPathComponent("reversed-report/swift")
        try writeReport(diagnostics: diags.reversed(), to: otherDir)
        let reversed = try artifactData("findings.json", in: otherDir)
        XCTAssertEqual(forward, reversed, "findings.json ordering must not depend on input order")
    }

    func testFindings_containsNoTimestampAndRelativePaths() throws {
        try writeReport(diagnostics: [makeDiagnostic(file: "Views/MyView.swift")])
        let findings = try artifactJSON("findings.json")
        let entries = try XCTUnwrap(findings["findings"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["filePath"] as? String, "Views/MyView.swift")

        let raw = String(decoding: try artifactData("findings.json"), as: UTF8.self)
        XCTAssertFalse(raw.contains("generatedAt"))
        XCTAssertFalse(raw.contains(tempRoot), "findings.json must not embed the absolute analysis root")
    }

    // MARK: - summary.json manifest

    func testSummary_containsMetadataAndRollups() throws {
        let diags = [
            makeDiagnostic(),
            makeDiagnostic(ruleID: "fixed-font-size", line: 20, severity: .warning, message: "Fixed font size"),
        ]
        try writeReport(diagnostics: diags)
        let summary = try artifactJSON("summary.json")

        XCTAssertEqual(summary["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(summary["generatedAt"] as? String)

        let tool = try XCTUnwrap(summary["tool"] as? [String: Any])
        XCTAssertEqual(tool["name"] as? String, "a11y-check")
        XCTAssertEqual(tool["version"] as? String, "0.0.0-test")
        XCTAssertEqual(tool["buildCommit"] as? String, "abc1234")

        let score = try XCTUnwrap(summary["score"] as? [String: Any])
        XCTAssertNotNil(score["score"] as? Double)
        XCTAssertNotNil(score["grade"] as? String)

        let counts = try XCTUnwrap(summary["counts"] as? [String: Any])
        XCTAssertEqual(counts["errors"] as? Int, 1)
        XCTAssertEqual(counts["warnings"] as? Int, 1)
        XCTAssertEqual(counts["total"] as? Int, 2)
        let byRule = try XCTUnwrap(counts["byRule"] as? [String: Int])
        XCTAssertEqual(byRule["image-missing-label"], 1)
        XCTAssertEqual(byRule["fixed-font-size"], 1)
        let byCriterion = try XCTUnwrap(counts["byWCAGCriterion"] as? [String: Int])
        XCTAssertEqual(byCriterion["1.1.1"], 2)

        let criteria = try XCTUnwrap(summary["criteria"] as? [String: Any])
        XCTAssertNotNil(criteria["passed"] as? Int)
        XCTAssertNotNil(criteria["failed"] as? Int)
        XCTAssertNotNil(criteria["notChecked"] as? Int)

        XCTAssertNotNil(summary["filesAnalyzed"] as? Int)
    }

    // MARK: - Run-over-run delta

    func testDelta_isNilOnFirstRun() throws {
        let result = try writeReport(diagnostics: [makeDiagnostic()])
        XCTAssertNil(result.delta)
        let summary = try artifactJSON("summary.json")
        XCTAssertNil(summary["delta"], "summary.json must omit delta on the first run")
    }

    func testDelta_classifiesNewFixedPersisting() throws {
        let issueA = makeDiagnostic(ruleID: "rule-a", file: "A.swift", message: "issue A")
        let issueB = makeDiagnostic(ruleID: "rule-b", file: "B.swift", message: "issue B")
        let issueC = makeDiagnostic(ruleID: "rule-c", file: "C.swift", message: "issue C")

        try writeReport(diagnostics: [issueA, issueB])
        let result = try writeReport(diagnostics: [issueB, issueC])

        let delta = try XCTUnwrap(result.delta)
        XCTAssertEqual(delta.new, 1)
        XCTAssertEqual(delta.fixed, 1)
        XCTAssertEqual(delta.persisting, 1)

        let summary = try artifactJSON("summary.json")
        let summaryDelta = try XCTUnwrap(summary["delta"] as? [String: Any])
        XCTAssertEqual(summaryDelta["new"] as? Int, 1)
        XCTAssertEqual(summaryDelta["fixed"] as? Int, 1)
        XCTAssertEqual(summaryDelta["persisting"] as? Int, 1)
    }

    func testDelta_ignoresLineNumberShifts() throws {
        try writeReport(diagnostics: [makeDiagnostic(line: 10)])
        let result = try writeReport(diagnostics: [makeDiagnostic(line: 42)])
        let delta = try XCTUnwrap(result.delta)
        XCTAssertEqual(delta.new, 0)
        XCTAssertEqual(delta.fixed, 0)
        XCTAssertEqual(delta.persisting, 1)
    }

    func testDelta_corruptPreviousSnapshotIsNonFatal() throws {
        try FileManager.default.createDirectory(atPath: platformDir, withIntermediateDirectories: true)
        let findingsPath = (platformDir as NSString).appendingPathComponent("findings.json")
        try Data("not json {".utf8).write(to: URL(fileURLWithPath: findingsPath))

        let result = try writeReport(diagnostics: [makeDiagnostic()])
        XCTAssertNil(result.delta)
        XCTAssertEqual(result.warnings.count, 1)

        // The corrupt snapshot must have been replaced with a valid one
        let findings = try artifactJSON("findings.json")
        XCTAssertEqual((findings["findings"] as? [Any])?.count, 1)
    }

    // MARK: - Legacy relocation / fallback

    func testMigrateLegacyScores_seedsFolderFormFromLegacyFile() throws {
        let legacyTracker = TrendTracker(directory: tempRoot)
        let score = makeScore(diagnostics: [], registry: RuleRegistry())
        legacyTracker.record(score: score)
        let legacyPath = (tempRoot as NSString).appendingPathComponent(".a11y-scores.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath))

        let migrated = try ReportLayout.migrateLegacyScores(analysisRoot: tempRoot, platformDir: platformDir)
        XCTAssertTrue(migrated)

        let newTracker = TrendTracker(directory: platformDir, fileName: ReportLayout.scoresFileName)
        XCTAssertEqual(newTracker.load().entries.count, 1, "legacy history must carry over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath), "legacy file must be left in place")
    }

    func testMigrateLegacyScores_doesNotOverwriteExistingFolderForm() throws {
        try FileManager.default.createDirectory(atPath: platformDir, withIntermediateDirectories: true)
        let newPath = ReportLayout.scoresPath(platformDir: platformDir)
        try Data(#"{"entries":[]}"#.utf8).write(to: URL(fileURLWithPath: newPath))

        let legacyPath = (tempRoot as NSString).appendingPathComponent(".a11y-scores.json")
        try Data(#"{"entries":[]}"#.utf8).write(to: URL(fileURLWithPath: legacyPath))

        let migrated = try ReportLayout.migrateLegacyScores(analysisRoot: tempRoot, platformDir: platformDir)
        XCTAssertFalse(migrated, "existing folder-form scores.json must win over legacy")
    }

    func testMigrateLegacyScores_noopWhenNoLegacyFile() throws {
        let migrated = try ReportLayout.migrateLegacyScores(analysisRoot: tempRoot, platformDir: platformDir)
        XCTAssertFalse(migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReportLayout.scoresPath(platformDir: platformDir)))
    }

    func testBaseline_savesAndLoadsAtFolderFormPath() throws {
        try FileManager.default.createDirectory(atPath: platformDir, withIntermediateDirectories: true)
        let baselinePath = ReportLayout.baselinePath(platformDir: platformDir)

        let baseline = Baseline.from(diagnostics: [makeDiagnostic()], score: 88.0)
        try baseline.save(toPath: baselinePath)

        let loaded = try XCTUnwrap(Baseline.load(atPath: baselinePath))
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.score, 88.0)
    }
}
