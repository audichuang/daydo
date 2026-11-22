import Foundation
import Testing
@testable import DayDoCore

@Suite struct DescriptionLinksTests {
    private func links(in attributed: AttributedString) -> [(text: String, url: URL)] {
        attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed[run.range].characters), url)
        }
    }

    @Test func markdownLinkRendersLabelWithURLAttached() {
        let input = "請看 [在地圖開啟](https://maps.apple.com/?q=一番地壽喜燒%20內湖宏匯店&address=台北市內湖區瑞光路333號1樓) 確認地點"
        let out = DescriptionLinks.linkified(input)

        #expect(String(out.characters) == "請看 在地圖開啟 確認地點")
        let found = links(in: out)
        #expect(found.count == 1)
        #expect(found[0].text == "在地圖開啟")
        #expect(found[0].url.scheme == "https")
        #expect(found[0].url.host() == "maps.apple.com")
        // Already percent-encoded `%20` must not be double-encoded into `%2520`.
        #expect(!found[0].url.absoluteString.contains("%2520"))
        let queryItems = URLComponents(url: found[0].url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(queryItems?.first(where: { $0.name == "q" })?.value == "一番地壽喜燒 內湖宏匯店")
        #expect(queryItems?.first(where: { $0.name == "address" })?.value == "台北市內湖區瑞光路333號1樓")
    }

    @Test func bareHTTPSURLBecomesLink() {
        let input = "參考 https://example.com/docs?a=1 說明"
        let out = DescriptionLinks.linkified(input)

        #expect(String(out.characters) == input)
        let found = links(in: out)
        #expect(found.count == 1)
        #expect(found[0].text == "https://example.com/docs?a=1")
        #expect(found[0].url == URL(string: "https://example.com/docs?a=1"))
    }

    @Test func taiwanesePhoneBecomesDigitsOnlyTelLink() {
        let input = "訂位電話：02-7756-6298"
        let out = DescriptionLinks.linkified(input)

        #expect(String(out.characters) == input)
        let found = links(in: out)
        #expect(found.count == 1)
        #expect(found[0].text == "02-7756-6298")
        #expect(found[0].url == URL(string: "tel:0277566298"))
    }

    @Test func internationalPhoneKeepsPlusPrefix() {
        let found = links(in: DescriptionLinks.linkified("+886 2 7756 6298"))
        #expect(found.count == 1)
        #expect(found[0].url == URL(string: "tel:+886277566298"))
    }

    @Test func phoneExtensionDialsAfterPause() {
        let found = links(in: DescriptionLinks.linkified("(415) 555-2671 ext. 42"))
        #expect(found.count == 1)
        #expect(found[0].url == URL(string: "tel:4155552671,42"))
    }

    @Test func plainTextAndOtherMarkdownSyntaxStayUnchanged() {
        let input = "12:00・3 人・*星號* _底線_ `code`\n待確認：用餐時間"
        let out = DescriptionLinks.linkified(input)

        #expect(String(out.characters) == input)
        #expect(links(in: out).isEmpty)
    }

    @Test func malformedMarkdownLinksAreLeftAsIs() {
        for input in ["[x](", "[x]()", "[x](not-a-url)", "[](https://example.com)"] {
            let out = DescriptionLinks.linkified(input)
            #expect(String(out.characters) == input)
        }
        #expect(links(in: DescriptionLinks.linkified("[x](")).isEmpty)
        #expect(links(in: DescriptionLinks.linkified("[x]()")).isEmpty)
        #expect(links(in: DescriptionLinks.linkified("[x](not-a-url)")).isEmpty)
    }

    @Test func fullAssistantDescriptionExample() {
        let input = """
        12:00・3 人・冠安副理請客

        台北市內湖區瑞光路 333 號 1 樓（宏匯瑞光廣場）
        02-7756-6298
        [在地圖開啟](https://maps.apple.com/?q=一番地壽喜燒%20內湖宏匯店&address=台北市內湖區瑞光路333號1樓)

        待確認：用餐時間
        """
        let out = DescriptionLinks.linkified(input)
        let rendered = String(out.characters)

        #expect(rendered.contains("在地圖開啟"))
        #expect(!rendered.contains("](https"))
        #expect(rendered.contains("02-7756-6298"))
        #expect(rendered.contains("待確認：用餐時間"))

        let found = links(in: out)
        #expect(found.count == 2)
        #expect(found[0].text == "02-7756-6298")
        #expect(found[0].url == URL(string: "tel:0277566298"))
        #expect(found[1].text == "在地圖開啟")
        #expect(found[1].url.host() == "maps.apple.com")
    }
}
