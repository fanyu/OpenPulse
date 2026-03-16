import SwiftUI
import SwiftData
import Charts

struct CompareView: View {
    @Query(sort: \DailyStatsRecord.date) private var dailyStats: [DailyStatsRecord]
    @State private var range: DateRange = .week

    enum DateRange: String, CaseIterable {
        case week = "7 Days"
        case month = "30 Days"
        case quarter = "90 Days"

        var days: Int {
            switch self { case .week: 7; case .month: 30; case .quarter: 90 }
        }
    }

    private var filteredStats: [DailyStatsRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: Date())!
        return dailyStats.filter { $0.date >= cutoff }
    }

    private var aggregateByTool: [Tool: Int] {
        Dictionary(grouping: filteredStats, by: { $0.tool })
            .mapValues { $0.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Range", selection: $range) {
                    ForEach(DateRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                tokenTimelineChart
                toolShareChart
                heatmapSection
            }
            .padding(24)
        }
        .navigationTitle("Compare")
        .background(.background)
    }

    // MARK: - Token Timeline

    private var tokenTimelineChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token Usage Over Time")
                .font(.title2).bold()

            Chart(filteredStats) { stat in
                LineMark(
                    x: .value("Date", stat.date, unit: .day),
                    y: .value("Tokens", stat.totalInputTokens + stat.totalOutputTokens)
                )
                .foregroundStyle(by: .value("Tool", stat.tool.displayName))
                AreaMark(
                    x: .value("Date", stat.date, unit: .day),
                    y: .value("Tokens", stat.totalInputTokens + stat.totalOutputTokens)
                )
                .foregroundStyle(by: .value("Tool", stat.tool.displayName))
                .opacity(0.1)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: range == .week ? .day : .weekOfYear)) { v in
                    AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month().day())
                }
            }
            .frame(height: 220)
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Tool Share

    private var toolShareChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage by Tool")
                .font(.title2).bold()

            HStack(spacing: 16) {
                Chart(Tool.allCases, id: \.self) { tool in
                    SectorMark(
                        angle: .value("Tokens", aggregateByTool[tool] ?? 0),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Tool", tool.displayName))
                    .cornerRadius(4)
                }
                .frame(height: 160)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        let tokens = aggregateByTool[tool] ?? 0
                        HStack(spacing: 8) {
                            ToolLogoImage(tool: tool, size: 20)
                            Text(tool.displayName)
                                .font(.caption)
                            Spacer()
                            Text(tokens.formatted(.number))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Activity Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Heatmap")
                .font(.title2).bold()
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}
