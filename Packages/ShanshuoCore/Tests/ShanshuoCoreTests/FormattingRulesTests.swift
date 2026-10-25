import Foundation
import Testing

@testable import ShanshuoCore

@Suite("Formatting rules")
struct FormattingRulesTests {
  @Test("only the two exact official HTTPS bases can create a messages URL")
  func endpointsAreStrict() {
    #expect(
      FormattingEndpoint.messagesURL(
        from: URL(string: "https://api.minimaxi.com/anthropic")!
      )?.absoluteString == "https://api.minimaxi.com/anthropic/v1/messages"
    )
    #expect(
      FormattingEndpoint.messagesURL(
        from: URL(string: "https://api.minimax.io/anthropic")!
      )?.absoluteString == "https://api.minimax.io/anthropic/v1/messages"
    )

    let rejected = [
      "http://api.minimaxi.com/anthropic",
      "https://api.minimaxi.com:443/anthropic",
      "https://api.minimaxi.com/anthropic?endpoint=other",
      "https://key@api.minimaxi.com/anthropic",
      "https://api.minimaxi.com/anthropic/extra",
      "https://evil.example/anthropic",
    ]
    for value in rejected {
      #expect(FormattingEndpoint.messagesURL(from: URL(string: value)!) == nil)
    }
    #expect(
      FormattingEndpoint.domestic.privacyPolicyURL.absoluteString
        == "https://platform.minimax.cn/protocol/privacy-policy"
    )
    #expect(
      FormattingEndpoint.international.privacyPolicyURL.absoluteString
        == "https://platform.minimax.io/protocol/privacy-policy"
    )
    #expect(
      FormattingEndpoint.domestic.apiKeyURL.absoluteString
        == "https://platform.minimax.cn/console/access?tab=api-keys"
    )
    #expect(
      FormattingEndpoint.international.apiKeyURL.absoluteString
        == "https://platform.minimax.io/console/access"
    )
  }

  @Test("the request is bounded and contains no dictionary terms")
  func requestBoundaries() {
    let accepted = FormattingRequest(originalText: "第一，买牛奶", dictionaryTerms: [])
    #expect(FormattingRules.requestValidation(accepted) == .accepted)

    let oversized = FormattingRequest(
      originalText: String(repeating: "字", count: FormattingRules.maximumRequestScalars + 1),
      dictionaryTerms: []
    )
    #expect(FormattingRules.requestValidation(oversized) == .tooLong)

    let terms = FormattingRequest(originalText: "测试", dictionaryTerms: ["不应上传"])
    #expect(FormattingRules.requestValidation(terms) == .dictionaryTermsNotAllowed)
  }

  @Test("the fidelity guard allows known cleanup but rejects clear distortion")
  func fidelityGuard() {
    #expect(
      FormattingRules.fidelityValidation(
        original: "嗯那个我们周三不对周四下午开会",
        candidate: "我们周四下午开会。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "嗯那个我们周三不对周四下午开会",
        candidate: "我们周三和周四下午开会。"
      ) == .staleCorrection
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "预算是 42 元，周四交给老王",
        candidate: "周四交给老王。"
      ) == .missingFactAnchor
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "帮我写一封请假邮件",
        candidate: "主题：请假申请\n\n尊敬的领导："
      ) == .answerLikeResponse
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "买牛奶",
        candidate: String(repeating: "这是额外扩写。", count: 80)
      ) == .excessiveExpansion
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "明天北京天气怎么样",
        candidate: "明天北京晴天，气温25度。"
      ) == .addedFactAnchor
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "预算二十元",
        candidate: "预算20元。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "第一买牛奶第二取快递",
        candidate: "1. 买牛奶\n2. 取快递"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "买牛奶取快递",
        candidate: "- 买牛奶\n- 取快递"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "周一开会，周三不对周四交付",
        candidate: "周一开会，周四交付。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "预算是20元，周四交给老王",
        candidate: "预算是二十元，周四交给老王。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "好的，明天见",
        candidate: "好的，明天见。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "版本二零二六开始支持这个功能",
        candidate: "版本 2026 开始支持这个功能。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "预算是一百万元",
        candidate: "预算是 1000000 元。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "预算是一百万元",
        candidate: "预算是 1000001 元。"
      ) == .addedFactAnchor
    )
  }

  @Test("the fidelity guard retains an explicit spoken-list context before items")
  func explicitListContextGuard() {
    let original = "今天要做三件事第一确认报价第二发合同第三安排演示"

    #expect(
      FormattingRules.fidelityValidation(
        original: original,
        candidate: "1. 确认报价\n2. 发合同\n3. 安排演示"
      ) == .missingFactAnchor
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: original,
        candidate: "今天要做 3 件事：\n1. 确认报价\n2. 发合同\n3. 安排演示。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "第一确认报价第二发合同",
        candidate: "1. 确认报价\n2. 发合同。"
      ) == .accepted
    )
  }

  @Test("the fidelity guard treats valid thousands separators as the same quantity")
  func thousandsSeparatorNormalization() {
    #expect(
      FormattingRules.fidelityValidation(
        original: "这次报销 1,200 元",
        candidate: "这次报销 1200 元。"
      ) == .accepted
    )
    #expect(
      FormattingRules.fidelityValidation(
        original: "这次报销 12,000 元",
        candidate: "这次报销 1200 元。"
      ) != .accepted
    )
  }

  @Test("the production prompt names the confirmed formatting boundaries")
  func promptContract() {
    #expect(FormattingRules.systemPrompt.contains("1. "))
    #expect(FormattingRules.systemPrompt.contains("- "))
    #expect(FormattingRules.systemPrompt.contains("final correction"))
    #expect(FormattingRules.systemPrompt.contains("new paragraph"))
    #expect(FormattingRules.systemPrompt.contains("percentages"))
    #expect(FormattingRules.systemPrompt.contains("idioms"))
    #expect(FormattingRules.systemPrompt.contains("Chinese-English spacing"))
    #expect(FormattingRules.systemPrompt.contains("Do not answer"))
    #expect(FormattingRules.systemPrompt.contains("introductory time, people, and context"))
    #expect(FormattingRules.systemPrompt.contains("ordinary line before the list items"))
  }

  @Test("response parsing only accepts text blocks with a complete turn")
  func responseParsing() throws {
    let valid = try JSONSerialization.data(
      withJSONObject: [
        "type": "message",
        "stop_reason": "end_turn",
        "content": [
          ["type": "thinking", "thinking": "internal"],
          ["type": "text", "text": "1. 买牛奶"],
        ],
      ]
    )
    #expect(FormattingRules.parseResponse(valid) == .text("1. 买牛奶"))

    let tool = try JSONSerialization.data(
      withJSONObject: [
        "type": "message",
        "stop_reason": "end_turn",
        "content": [["type": "tool_use", "name": "send_email"]],
      ]
    )
    #expect(FormattingRules.parseResponse(tool) == .rejected(.toolUse))

    let truncated = try JSONSerialization.data(
      withJSONObject: [
        "type": "message",
        "stop_reason": "max_tokens",
        "content": [["type": "text", "text": "未完成"]],
      ]
    )
    #expect(FormattingRules.parseResponse(truncated) == .rejected(.incompleteTurn))

    let errorPayload = try JSONSerialization.data(
      withJSONObject: ["type": "error", "error": ["type": "rate_limit_error"]]
    )
    #expect(FormattingRules.parseResponse(errorPayload) == .rejected(.providerError))
  }

  @Test("provider body keeps data separate from instructions and model-specific thinking settings")
  func providerBody() throws {
    let request = FormattingRequest(originalText: "第一买牛奶", dictionaryTerms: [])
    let flashData = try #require(FormattingRules.requestBody(for: request, model: .flash))
    let flash = try JSONSerialization.jsonObject(with: flashData) as! [String: Any]
    #expect(flash["model"] as? String == FormattingModel.flash.rawValue)
    #expect(flash["max_tokens"] as? Int == FormattingRules.maximumTokens)
    #expect((flash["output_config"] as? [String: Any])?["effort"] as? String == "low")
    #expect(flash["thinking"] == nil)
    let messages = try #require(flash["messages"] as? [[String: String]])
    #expect(messages[0]["content"]?.contains("<dictation-data>") == true)
    #expect(messages[0]["content"]?.contains("dictionary_terms") == true)

    let m3Data = try #require(FormattingRules.requestBody(for: request, model: .m3))
    let m3 = try JSONSerialization.jsonObject(with: m3Data) as! [String: Any]
    #expect(m3["output_config"] == nil)
    #expect(m3["thinking"] == nil)
  }
}
