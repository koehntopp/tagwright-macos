import XCTest
@testable import Tagwright

final class NamingTests: XCTestCase {
	func testClean() {
		XCTAssertEqual(Naming.clean("Café del Mar: Vol. 1"), "Cafe_del_Mar_Vol_1")
		XCTAssertEqual(Naming.clean("Don't Stop"), "Dont_Stop")
		XCTAssertEqual(Naming.clean("Straße"), "Strasse")
	}
	func testBlissName() {
		XCTAssertEqual(Naming.blissName(["TITLE": ["Frost"], "TRACKNUMBER": ["1/9"], "DISCNUMBER": ["1"]]), "01_01_Frost.flac")
		XCTAssertNil(Naming.blissName(["TITLE": ["Frost"], "TRACKNUMBER": ["1"]]))
	}
	func testVersion() {
		XCTAssertEqual(Naming.versionString(year: "2021", dr: "11", format: "CD", edition: "", catalog: "TWS-202"), "2021 DR11 CD (TWS-202)")
	}
}

final class FlagTests: XCTestCase {
	func testFlags() {
		XCTAssertEqual(Flag.of("UK"), "🇬🇧"); XCTAssertEqual(Flag.of("Europe"), "🇪🇺"); XCTAssertEqual(Flag.of("XE"), "🇪🇺")
		XCTAssertEqual(Flag.of("Germany"), "🇩🇪"); XCTAssertEqual(Flag.of("de"), "🇩🇪"); XCTAssertEqual(Flag.of("Japan"), "🇯🇵")
		XCTAssertEqual(Flag.of("Worldwide"), ""); XCTAssertEqual(Flag.of(""), "")
	}
}
