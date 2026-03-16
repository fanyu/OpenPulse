import Foundation

struct ModelPricing {
    enum Currency { case usd, cny }

    let pattern: String          // lowercased substring match
    let inputPer1M: Double       // currency units per 1M tokens
    let outputPer1M: Double
    let cacheReadMultiplier: Double  // fraction of inputPer1M
    let currency: Currency

    // Match order matters — most specific patterns first
    static let table: [ModelPricing] = [
        // Claude 4
        ModelPricing(pattern: "claude-opus-4",      inputPer1M: 15.00, outputPer1M: 75.00, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "claude-sonnet-4",    inputPer1M:  3.00, outputPer1M: 15.00, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "claude-haiku-4",     inputPer1M:  0.80, outputPer1M:  4.00, cacheReadMultiplier: 0.1, currency: .usd),
        // Claude 3.x
        ModelPricing(pattern: "claude-3-5-sonnet",  inputPer1M:  3.00, outputPer1M: 15.00, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "claude-3-opus",      inputPer1M: 15.00, outputPer1M: 75.00, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "claude-3-haiku",     inputPer1M:  0.25, outputPer1M:  1.25, cacheReadMultiplier: 0.1, currency: .usd),
        // OpenAI Codex CLI (gpt-5.x-codex-mini → mini tier, gpt-5.x-codex → full tier)
        ModelPricing(pattern: "codex-mini",         inputPer1M:  1.50, outputPer1M:  6.00, cacheReadMultiplier: 0.25, currency: .usd),
        ModelPricing(pattern: "codex",              inputPer1M:  3.00, outputPer1M: 12.00, cacheReadMultiplier: 0.25, currency: .usd),
        // OpenAI reasoning & chat
        ModelPricing(pattern: "o4-mini",            inputPer1M:  1.10, outputPer1M:  4.40, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "o3",                 inputPer1M: 10.00, outputPer1M: 40.00, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "gpt-4o-mini",        inputPer1M:  0.15, outputPer1M:  0.60, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "gpt-4o",             inputPer1M:  2.50, outputPer1M: 10.00, cacheReadMultiplier: 0.1, currency: .usd),
        // DeepSeek
        ModelPricing(pattern: "deepseek-reasoner",  inputPer1M:  0.55, outputPer1M:  2.19, cacheReadMultiplier: 0.1, currency: .usd),
        ModelPricing(pattern: "deepseek-chat",      inputPer1M:  0.27, outputPer1M:  1.10, cacheReadMultiplier: 0.1, currency: .usd),
        // Kimi
        ModelPricing(pattern: "moonshot-v1-128k",   inputPer1M: 60.00, outputPer1M: 60.00, cacheReadMultiplier: 0.1, currency: .cny),
        ModelPricing(pattern: "moonshot-v1-32k",    inputPer1M: 24.00, outputPer1M: 24.00, cacheReadMultiplier: 0.1, currency: .cny),
        ModelPricing(pattern: "moonshot-v1-8k",     inputPer1M: 12.00, outputPer1M: 12.00, cacheReadMultiplier: 0.1, currency: .cny),
    ]

    static func pricing(for model: String) -> ModelPricing? {
        let lower = model.lowercased()
        return table.first { lower.contains($0.pattern) }
    }
}

struct SessionCost {
    let usd: Double?
    let cny: Double?
}

extension SessionRecord {
    var estimatedCost: SessionCost {
        guard let p = ModelPricing.pricing(for: model) else {
            return SessionCost(usd: nil, cny: nil)
        }
        let total = Double(inputTokens)     / 1_000_000 * p.inputPer1M
                  + Double(outputTokens)    / 1_000_000 * p.outputPer1M
                  + Double(cacheReadTokens) / 1_000_000 * (p.inputPer1M * p.cacheReadMultiplier)
        return p.currency == .usd
            ? SessionCost(usd: total, cny: nil)
            : SessionCost(usd: nil, cny: total)
    }
}
