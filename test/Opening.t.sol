// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {ReentrantBuyer} from "./helpers/Adversaries.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

contract OpeningTest is BoxTestBase {
    function test_MaturityWrongHeadersAndAlreadyOpened() public {
        uint256 purchase = buy(3);
        uint256 targetBlock = target(purchase);
        for (uint256 at = targetBlock - 3; at <= targetBlock; ++at) {
            vm.roll(at);
            vm.expectRevert(abi.encodeWithSelector(OGClubBox.TargetBlockNotPassed.selector, targetBlock));
            box.open(purchase, "");
            vm.expectRevert(abi.encodeWithSelector(OGClubBox.TargetBlockNotPassed.selector, targetBlock));
            box.previewOpen(purchase, bytes32(0));
        }
        bytes32 randao = keccak256("randomness");
        bytes memory header = ready(purchase, randao);
        vm.expectRevert(OGClubBox.HeaderHashMismatch.selector);
        box.open(purchase, "wrong header");
        bytes memory other = HeaderBuilder.header(targetBlock - 1, randao, 7);
        vm.setBlockhash(targetBlock - 1, keccak256(other));
        vm.expectRevert(OGClubBox.HeaderHashMismatch.selector);
        box.open(purchase, other);
        assertOpenMatches(purchase, randao, header, false);
        assertEq(furniture.balanceOf(stranger, 1), 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, purchase));
        box.open(purchase, header);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, purchase));
        box.previewOpen(purchase, randao);
    }

    function test_AuthenticatedHeaderMustHaveCorrectNumber() public {
        uint256 purchase = buy(1);
        uint256 targetBlock = target(purchase);
        vm.roll(targetBlock + 1);
        bytes memory wrongNumber = HeaderBuilder.header(targetBlock + 1, bytes32(uint256(42)), 7);
        vm.setBlockhash(targetBlock, keccak256(wrongNumber));
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.HeaderNumberMismatch.selector, targetBlock, targetBlock + 1));
        box.open(purchase, wrongNumber);
    }

    function test_UnknownPurchase() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.UnknownPurchase.selector, 0));
        box.open(0, "");
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.UnknownPurchase.selector, 1));
        box.open(1, "");
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.UnknownPurchase.selector, 1));
        box.previewOpen(1, bytes32(0));
    }

    function test_OpenWhileClosedPausedAndPastSaleEnd() public {
        uint256 purchase = buy(10);
        box.closeSeason(seasonId);
        box.setPaused(true);
        vm.warp(1_000_000);
        bytes32 randao = keccak256("closed");
        bytes memory header = ready(purchase, randao);
        assertOpenMatches(purchase, randao, header, false);
    }

    function test_ExactExpiryBoundaryAndIgnoredHeader() public {
        uint256 live = buy(10);
        uint256 expired = buy(10);
        uint256 targetBlock = target(live);
        bytes32 randao = keccak256("boundary");
        bytes memory header = HeaderBuilder.header(targetBlock, randao, 7);
        vm.roll(targetBlock + 256);
        vm.setBlockhash(targetBlock, keccak256(header));
        assertOpenMatches(live, randao, header, false);
        vm.roll(targetBlock + 257);
        uint256[] memory expected = box.previewOpen(expired, randao);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(expected[i], 1);
        }
        assertOpenMatches(expired, randao, hex"ffff0000", true);
    }

    function testFuzz_ExpiredAlwaysFallback(uint8 count, bytes32 randao, uint16 delay) public {
        count = uint8(bound(count, 1, 10));
        uint256 purchase = buy(count);
        vm.roll(target(purchase) + bound(delay, 257, type(uint16).max));
        uint256[] memory expected = box.previewOpen(purchase, randao);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(expected[i], 1);
        }
        assertOpenMatches(purchase, randao, abi.encode(randao), true);
        assertEq(box.minted(seasonId, 1), count);
    }

    function test_BuilderFieldsDoNotAffectRoll() public {
        uint256 purchase = buy(10);
        bytes32 randao = keccak256("fixed prevRandao");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        uint256 snapshot = vm.snapshotState();
        assertOpenMatches(purchase, randao, header, false);
        assertTrue(vm.revertToState(snapshot));
        bytes[] memory fields = HeaderBuilder.fields(target(purchase), randao, 15);
        fields[2] = abi.encodePacked(makeAddr("different coinbase"));
        fields[11] = HeaderBuilder.uintBytes(987654321);
        fields[12] = bytes("builder can grind this extraData");
        header = HeaderBuilder.list(fields);
        vm.setBlockhash(target(purchase), keccak256(header));
        vm.warp(77777);
        vm.coinbase(makeAddr("open block coinbase"));
        vm.prevrandao(keccak256("open block randao"));
        assertEq(box.previewOpen(purchase, randao), expected);
        assertOpenMatches(purchase, randao, header, false);
    }

    function testFuzz_PreviewMatchesOpenAndCaps(bytes32 randao, uint8 count) public {
        count = uint8(bound(count, 1, 10));
        for (uint256 round; round < 4; ++round) {
            uint256 purchase = buy(count);
            randao = keccak256(abi.encode(randao, round));
            bytes memory header = ready(purchase, randao);
            assertOpenMatches(purchase, randao, header, false);
        }
    }

    function test_ReceiverReentrancySingleAndBatch() public {
        for (uint256 count = 1; count <= 10; count += 9) {
            ReentrantBuyer receiver = new ReentrantBuyer(box, token, seasonId);
            token.mint(address(receiver), 10_000);
            uint256 purchase = receiver.buy(count);
            bytes32 randao = keccak256(abi.encode("callback", count));
            bytes memory header = ready(purchase, randao);
            receiver.configure(header, false);
            uint256 supply = furniture.totalSupply();
            assertOpenMatches(purchase, randao, header, false);
            assertEq(furniture.totalSupply(), supply + count);
            assertEq(receiver.callbacks(), 1);
            assertTrue(receiver.sawOpened());
            assertFalse(receiver.openSucceeded());
            assertFalse(receiver.otherOpenSucceeded());
            assertFalse(receiver.buySucceeded());
            assertFalse(receiver.deliverSucceeded());
            assertFalse(receiver.deliverToSucceeded());
            assertFalse(receiver.otherDeliverSucceeded());
            assertEq(receiver.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            assertEq(receiver.deliverToError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            assertEq(receiver.openError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            assertEq(receiver.buyError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            (,,,, bool opened) = box.purchases(receiver.otherPurchaseId());
            assertFalse(opened);
        }
        assertEq(box.purchaseCount(), 4);
    }

    function test_RejectedFirstDeliveryRecordsOpenedAndCapsAndCanRetry() public {
        ReentrantBuyer receiver = new ReentrantBuyer(box, token, seasonId);
        token.mint(address(receiver), 10_000);
        uint256 purchase = receiver.buy(10);
        bytes32 randao = keccak256("retry");
        bytes memory header = ready(purchase, randao);
        receiver.configure(header, true);
        uint256[] memory preview = box.previewOpen(purchase, randao);
        box.open(purchase, header);
        (,,,, bool opened) = box.purchases(purchase);
        assertTrue(opened);
        assertFalse(box.delivered(purchase));
        assertEq(furniture.totalSupply(), 0);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 expected;
            for (uint256 i; i < preview.length; ++i) {
                if (preview[i] == id) ++expected;
            }
            assertEq(box.minted(seasonId, id), expected);
        }
        assertEq(box.getStoredItems(purchase), preview);
        receiver.configure(header, false);
        vm.prank(stranger);
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        assertEq(furniture.totalSupply(), 10);
        assertEq(receiver.callbacks(), 1);
        assertTrue(receiver.sawDelivered());
        assertFalse(receiver.deliverSucceeded());
        assertFalse(receiver.deliverToSucceeded());
        assertFalse(receiver.otherDeliverSucceeded());
        assertFalse(receiver.openSucceeded());
        assertFalse(receiver.buySucceeded());
        assertEq(receiver.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.deliverToError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(address(receiver), id), box.minted(seasonId, id));
        }
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
    }

    function test_RevokedMinterRecordsRollAndDeliversAfterExpiryAndDelayedRestoration() public {
        // Existing supply makes re-authorization subject to seven days.
        uint256 first = buy(1);
        box.open(first, ready(first, keccak256("first")));
        uint256 purchase = buy(10);
        bytes32 randao = keccak256("revoked");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        uint256[] memory balancesBefore = new uint256[](4);
        bool nonFallback;
        for (uint256 id = 1; id <= 3; ++id) {
            balancesBefore[id] = furniture.balanceOf(buyer, id);
        }
        for (uint256 i; i < expected.length; ++i) {
            if (expected[i] != 1) nonFallback = true;
        }
        assertTrue(nonFallback);
        furniture.revokeMinter(address(box));
        vm.recordLogs();
        box.open(purchase, header);
        checkOpenLogs(purchase, expected, randao, false);
        (,,,, bool opened) = box.purchases(purchase);
        assertTrue(opened);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase), expected);
        assertEq(furniture.totalSupply(), 1);
        vm.roll(target(purchase) + 300);
        furniture.grantMinter(address(box));
        assertFalse(furniture.minters(address(box)));
        vm.expectRevert();
        box.deliver(purchase);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase), expected);
        vm.warp(furniture.pendingMinters(address(box)));
        vm.prank(stranger);
        furniture.activateMinter(address(box));
        box.setPaused(true);
        box.closeSeason(seasonId);
        vm.prank(stranger);
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 received;
            for (uint256 i; i < expected.length; ++i) {
                if (expected[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(buyer, id), balancesBefore[id] + received);
        }
        assertEq(furniture.totalSupply(), 11);
        assertEq(token.balanceOf(address(box)), 0);
    }
}
