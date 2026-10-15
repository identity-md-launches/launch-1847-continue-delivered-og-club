// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {ReentrantBuyer} from "./helpers/Adversaries.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

/// @dev A pick depends only on its seed and the season's original weights. Another open can only sell out a
///      capped entry, which degrades a pending pick of that entry to the fallback; it never re-maps the rest.
contract FixedOddsTest is BoxTestBase {
    uint256 internal constant COMMON = 1; // tier 0, weight 60, unlimited fallback
    uint256 internal constant LEGENDARY = 2; // tier 4, weight 10, unlimited
    uint256 internal constant BAIT = 3; // tier 1, weight 30, cap 1

    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](3);
        entries[0] = OGClubBox.Entry(COMMON, 0, 60, 0);
        entries[1] = OGClubBox.Entry(LEGENDARY, 4, 10, 0);
        entries[2] = OGClubBox.Entry(BAIT, 1, 30, 1);
        seasonId = box.createSeason(100, 1000, 100_000, 0, COMMON, entries);
        address[4] memory players = [alice, bob, carol, dave];
        for (uint256 i; i < players.length; ++i) {
            token.mint(players[i], 10_000);
            vm.prank(players[i]);
            token.approve(address(box), type(uint256).max);
        }
    }

    function buyAs(address who, uint256 count) internal returns (uint256) {
        vm.prank(who);
        return box.buy(seasonId, count);
    }

    function seedOf(bytes32 randao, uint256 purchaseId, uint256 index) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(randao, block.chainid, address(box), purchaseId, index)));
    }

    function entryOf(uint256 season, uint256 itemId) internal view returns (OGClubBox.Entry memory) {
        OGClubBox.Entry[] memory entries = box.getEntries(season);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].itemId == itemId) return entries[i];
        }
        revert("unknown item");
    }

    function tierOf(uint256 season, uint256 itemId) internal view returns (uint256) {
        return entryOf(season, itemId).tier;
    }

    /// @dev Over the season's weight of 100: a rolls Common, b rolls Legendary, c and d roll the capped Bait.
    function findRandao(uint256 a, uint256 b, uint256 c, uint256 d) internal view returns (bytes32 randao) {
        for (uint256 n; n < 100_000; ++n) {
            randao = keccak256(abi.encode("fixed odds", n));
            bool ok = seedOf(randao, a, 0) % 100 < 60;
            ok = ok && seedOf(randao, b, 0) % 100 >= 60 && seedOf(randao, b, 0) % 100 < 70;
            ok = ok && seedOf(randao, c, 0) % 100 >= 70;
            ok = ok && seedOf(randao, d, 0) % 100 >= 70;
            if (ok) return randao;
        }
        revert("no randao found");
    }

    function test_SellOutOnlyDegradesTheSoldOutPickAndNeverRemapsOthers() public {
        uint256 pAlice = buyAs(alice, 1);
        uint256 pBob = buyAs(bob, 1);
        uint256 pCarol = buyAs(carol, 1);
        uint256 pDave = buyAs(dave, 1);
        bytes32 randao = findRandao(pAlice, pBob, pCarol, pDave);
        bytes memory header = ready(pAlice, randao);
        assertEq(box.previewOpen(pAlice, randao)[0], COMMON);
        assertEq(box.previewOpen(pBob, randao)[0], LEGENDARY);
        assertEq(box.previewOpen(pCarol, randao)[0], BAIT);
        assertEq(box.previewOpen(pDave, randao)[0], BAIT);

        // Alice opens Carol's purchase (anyone may), which sells out the Bait.
        vm.prank(alice);
        box.open(pCarol, header);
        assertEq(box.minted(seasonId, BAIT), 1);
        assertEq(furniture.balanceOf(carol, BAIT), 1);

        // Pending picks of unlimited entries are unchanged; Dave's sold-out pick degrades to the fallback.
        assertEq(box.previewOpen(pAlice, randao)[0], COMMON, "waiting for a sell-out must not improve a roll");
        assertEq(box.previewOpen(pBob, randao)[0], LEGENDARY, "another open must not re-map an unrelated roll");
        assertEq(box.previewOpen(pDave, randao)[0], COMMON, "a sold-out pick becomes the fallback");
        assertOpenMatches(pAlice, randao, header, false);
        assertOpenMatches(pBob, randao, header, false);
        assertOpenMatches(pDave, randao, header, false);
        assertEq(furniture.balanceOf(alice, COMMON), 1);
        assertEq(furniture.balanceOf(bob, LEGENDARY), 1);
        assertEq(furniture.balanceOf(dave, COMMON), 1);
        assertEq(furniture.balanceOf(dave, BAIT), 0);
        assertEq(box.minted(seasonId, BAIT), 1);
    }

    function test_RejectedDeliveryCannotBeRetriedForABetterRoll() public {
        ReentrantBuyer receiver = new ReentrantBuyer(box, token, seasonId);
        token.mint(address(receiver), 10_000);
        uint256 pReceiver = receiver.buy(1); // Also records a second one-box purchase for the receiver.
        uint256 pOther = receiver.otherPurchaseId();
        uint256 pDave = buyAs(dave, 1);
        bytes32 randao = findRandao(pReceiver, pOther, pDave, pDave);
        bytes memory header = ready(pReceiver, randao);
        assertEq(box.previewOpen(pReceiver, randao)[0], COMMON);

        // The contract buyer rejects delivery, but cannot veto recording its Common roll.
        receiver.configure(header, true);
        vm.prank(stranger);
        box.open(pReceiver, header);
        (,,,, bool opened) = box.purchases(pReceiver);
        assertTrue(opened);
        assertFalse(box.delivered(pReceiver));

        // The Bait sells out while delivery is pending; the stored Common does not change.
        vm.prank(address(receiver));
        box.open(pDave, header);
        assertEq(box.minted(seasonId, BAIT), 1);
        assertEq(box.getStoredItems(pReceiver)[0], COMMON, "holding out must not earn a re-roll");
        receiver.configure(header, false);
        box.deliver(pReceiver);
        assertTrue(box.delivered(pReceiver));
        assertEq(furniture.balanceOf(address(receiver), COMMON), 1);
    }

    /// @dev Box 9 of the pack selects the capped Rare, boxes 0-8 avoid it, and the single purchase takes it.
    function findPackRandao(uint256 pack, uint256 single) internal view returns (bytes32 randao) {
        for (uint256 n; n < 100_000; ++n) {
            randao = keccak256(abi.encode("ten pack", n));
            bool ok = seedOf(randao, pack, 9) % 100 < 50;
            uint256 singleRoll = seedOf(randao, single, 0) % 200;
            ok = ok && singleRoll >= 100 && singleRoll < 150;
            for (uint256 i; ok && i < 9; ++i) {
                uint256 roll = seedOf(randao, pack, i) % 200;
                if (roll >= 100 && roll < 150) ok = false;
            }
            if (ok) return randao;
        }
        revert("no randao found");
    }

    function test_TenPackGuaranteeRerollsOnlyWhenItsOwnRareSellsOut() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](4);
        entries[0] = OGClubBox.Entry(1, 0, 100, 0);
        entries[1] = OGClubBox.Entry(2, 2, 50, 1);
        entries[2] = OGClubBox.Entry(3, 3, 25, 0);
        entries[3] = OGClubBox.Entry(4, 4, 25, 0);
        seasonId = box.createSeason(100, 1000, 100_000, 0, 1, entries);
        uint256 pack = buyAs(alice, 10);
        uint256 single = buyAs(bob, 1);
        bytes32 randao = findPackRandao(pack, single);
        bytes memory header = ready(pack, randao);
        uint256[] memory fresh = box.previewOpen(pack, randao);
        assertEq(fresh[9], 2, "box 9 selects over the full rare weight");
        assertEq(box.previewOpen(single, randao)[0], 2);
        assertOpenMatches(single, randao, header, false);
        assertEq(box.minted(seasonId, 2), 1);

        uint256[] memory later = box.previewOpen(pack, randao);
        for (uint256 i; i < 9; ++i) {
            assertEq(later[i], fresh[i], "boxes 0-8 are untouched by the sell-out");
        }
        assertTrue(later[9] == 3 || later[9] == 4, "box 9 re-rolls among the remaining rares");
        assertGe(tierOf(seasonId, later[9]), 2);
        assertOpenMatches(pack, randao, header, false);
        assertEq(box.minted(seasonId, 2), 1);
        assertEq(furniture.balanceOf(alice, 2), 0);
    }

    function test_RejectedTenPackReservesRareAndCannotUpgradeAfterAnotherOpen() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](4);
        entries[0] = OGClubBox.Entry(1, 0, 100, 0);
        entries[1] = OGClubBox.Entry(2, 2, 50, 1);
        entries[2] = OGClubBox.Entry(3, 3, 25, 0);
        entries[3] = OGClubBox.Entry(4, 4, 25, 0);
        seasonId = box.createSeason(100, 1000, 100_000, 0, 1, entries);
        ReentrantBuyer receiver = new ReentrantBuyer(box, token, seasonId);
        token.mint(address(receiver), 10_000);
        uint256 pack = receiver.buy(10);
        uint256 single = buyAs(bob, 1);
        bytes32 randao = findPackRandao(pack, single);
        bytes memory header = ready(pack, randao);
        uint256[] memory expected = box.previewOpen(pack, randao);
        assertEq(expected[9], 2);
        assertEq(box.previewOpen(single, randao)[0], 2);
        receiver.configure(header, true);
        vm.prank(stranger);
        box.open(pack, header);
        assertFalse(box.delivered(pack));
        assertEq(box.getStoredItems(pack), expected);
        assertEq(box.minted(seasonId, 2), 1);
        assertEq(furniture.totalSupply(2), 0);
        // The undelivered rare already consumes the cap, so this later pick must be fallback.
        assertEq(box.previewOpen(single, randao)[0], 1);
        assertOpenMatches(single, randao, header, false);
        assertEq(box.getStoredItems(pack), expected);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, pack));
        box.open(pack, header);
        receiver.configure(header, false);
        box.deliver(pack);
        for (uint256 id = 1; id <= 4; ++id) {
            uint256 received;
            for (uint256 i; i < expected.length; ++i) {
                if (expected[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(address(receiver), id), received);
        }
        assertEq(furniture.totalSupply(2), 1);
        assertEq(box.minted(seasonId, 2), 1);
    }

    function testFuzz_OtherOpensOnlyDegradeSoldOutPicks(bytes32 randao, uint8 countA, uint8 countB) public {
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, defaultEntries());
        countA = uint8(bound(countA, 1, 10));
        countB = uint8(bound(countB, 1, 10));
        uint256 first = buyAs(alice, countA);
        uint256 second = buyAs(bob, countB);
        bytes memory header = ready(first, randao);
        uint256[] memory fresh = box.previewOpen(first, randao);
        assertOpenMatches(second, randao, header, false);
        uint256[] memory later = box.previewOpen(first, randao);
        for (uint256 i; i < fresh.length; ++i) {
            if (later[i] == fresh[i]) continue;
            if (countA == 10 && i == 9) {
                uint256 raresLeft = 3 - box.minted(seasonId, 3);
                for (uint256 j; j < 9; ++j) {
                    if (later[j] == 3) --raresLeft;
                }
                if (raresLeft != 0) assertGe(tierOf(seasonId, later[i]), 2, "guarantee lost while a rare remained");
                assertLe(tierOf(seasonId, later[i]), tierOf(seasonId, fresh[i]), "guaranteed box improved");
                continue;
            }
            assertEq(later[i], 1, "a changed pick must be the fallback");
            OGClubBox.Entry memory was = entryOf(seasonId, fresh[i]);
            uint256 used = box.minted(seasonId, fresh[i]);
            for (uint256 j; j < i; ++j) {
                if (later[j] == fresh[i]) ++used;
            }
            assertGt(was.cap, 0, "only a capped entry can change");
            assertGe(used, was.cap, "only a sold-out entry can change");
        }
        assertOpenMatches(first, randao, header, false);
    }
}
