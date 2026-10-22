import Foundation
import Testing
@testable import YukinoCore

struct SidebarOrderTests {
    @Test func itemsStayInsideTheirCategory() {
        var order = SidebarOrder()
        let developer = ["json", "base64", "uuid"]
        let accepted1 = order.moveItem("uuid", in: "Developer", to: "json", after: false, available: developer)
        #expect(accepted1)
        #expect(order.orderedItems(in: "Developer", available: developer) == ["uuid", "json", "base64"])
        let accepted2 = !order.moveItem("port", in: "Developer", to: "json", after: false, available: developer)
        #expect(accepted2)
        let accepted3 = !order.moveItem("uuid", in: "Developer", to: "port", after: true, available: developer)
        #expect(accepted3)
        #expect(order.orderedItems(in: "Network", available: ["port", "process"]) == ["port", "process"])
        let accepted4 = order.moveItem("uuid", in: "Developer", to: "base64", after: true, available: developer)
        #expect(accepted4)
        #expect(order.orderedItems(in: "Developer", available: developer) == developer)
    }

    @Test func movingGroupsKeepsTheirChildrenAndSurvivesPersistence() throws {
        var order = SidebarOrder()
        let groups = ["Favorites", "AI", "Developer", "Network"]
        order.moveItem("uuid", in: "Developer", to: "json", after: false, available: ["json", "uuid"])
        let accepted5 = order.moveGroup("Network", to: "AI", after: false, available: groups)
        #expect(accepted5)
        let restored = try JSONDecoder().decode(SidebarOrder.self, from: JSONEncoder().encode(order))
        #expect(restored.orderedGroups(groups) == ["Favorites", "Network", "AI", "Developer"])
        #expect(restored.orderedItems(in: "Developer", available: ["json", "uuid"]) == ["uuid", "json"])
        #expect(restored.orderedItems(in: "Network", available: ["port", "process"]) == ["port", "process"])
    }

    @Test func hiddenEntriesSurviveAndNewEntriesAppend() {
        var order = SidebarOrder()
        order.moveGroup("Optional", to: "AI", after: false, available: ["AI", "Developer", "Optional"])
        order.moveGroup("Developer", to: "AI", after: false, available: ["AI", "Developer"])
        #expect(order.orderedGroups(["AI", "Developer", "Optional", "New"]) == ["Optional", "Developer", "AI", "New"])
        order.moveItem("c", in: "Developer", to: "a", after: false, available: ["a", "b", "c"])
        order.moveItem("b", in: "Developer", to: "a", after: false, available: ["a", "b"])
        #expect(order.orderedItems(in: "Developer", available: ["a", "b", "c", "d"]) == ["c", "b", "a", "d"])
        let accepted6 = !order.moveGroup("AI", to: "AI", after: true, available: ["AI"])
        #expect(accepted6)
    }
}
