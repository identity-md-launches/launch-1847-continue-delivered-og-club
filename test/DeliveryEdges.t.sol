// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Contract buyer with no receiver hook at all; `open` must still record its roll.
contract DeafBuyer {
    function buy(OGClubBox box, uint256 season, uint256 count) external returns (uint256) {
        return box.buy(season, count);
    }

    function deliverTo(OGClubBox box, uint256 purchaseId, address to) external {
        box.deliverTo(purchaseId, to);
    }
}

contract Holder is ERC1155Holder {}

/// @notice Edges of the open/deliver split: gas-starved opens, storage footprint, redirect targets,
///         arbitrary delays between open and delivery, and the furniture's "nothing minted yet" rule.
contract DeliveryEdgesTest is BoxTestBase {
    event Delivered(uint256 indexed purchaseId, address indexed to);
    event DeliveryFailed(uint256 indexed purchaseId);

    uint256 internal constant STORED_ITEMS_SLOT = 10;

    function storedLengthSlot(uint256 purchaseId) internal pure returns (bytes32) {
        return keccak256(abi.encode(purchaseId, STORED_ITEMS_SLOT));
    }

    function storedElementSlot(uint256 purchaseId, uint256 index) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(storedLengthSlot(purchaseId)))) + index);
    }

    function countOf(uint256[] memory ids, uint256 id) internal pure returns (uint256 n) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) ++n;
        }
    }

    // ----------------------------------------------------------------- gas-starved open

    /// @dev A caller who forwards too little gas for the mint cannot make `open` revert because of
    ///      delivery, cannot change the roll, and cannot stop anyone from delivering later.
    function test_GasStarvedOpenOfHonestBuyerStoresRollAndAnyoneDeliversLater() public {
        uint256 purchase = buy(10);
        bytes32 randao = keccak256("gas starved");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(box));
        emit DeliveryFailed(purchase);
        vm.prank(stranger);
        box.open{gas: 600_000}(purchase, header);
        checkOpenLogs(purchase, expected, randao, false);
        (,,,, bool opened) = box.purchases(purchase);
        assertTrue(opened);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase), expected);
        assertEq(furniture.totalSupply(), 0);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(box.minted(seasonId, id), countOf(expected, id), "caps reserved despite failed mint");
        }
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, purchase));
        box.open(purchase, header);
        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, buyer);
        vm.prank(stranger);
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(buyer, id), countOf(expected, id));
            assertEq(box.minted(seasonId, id), countOf(expected, id), "delivery never rolls again");
        }
        assertEq(furniture.totalSupply(), 10);
    }

    /// @dev Whatever gas `open` receives, it either reverts atomically or records the preview roll;
    ///      it never lands in a state where the roll is lost or the caps disagree with the record.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_OpenWithAnyGasIsAtomicOrRecordsThePreview(uint32 gas, uint8 count, bytes32 randao) public {
        count = uint8(bound(count, 1, 10));
        gas = uint32(bound(gas, 150_000, 1_500_000));
        uint256 purchase = buy(count);
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        (bool ok,) = address(box).call{gas: gas}(abi.encodeCall(box.open, (purchase, header)));
        (,,,, bool opened) = box.purchases(purchase);
        assertEq(opened, ok, "open is atomic");
        uint256 total;
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 reserved = ok ? countOf(expected, id) : 0;
            assertEq(box.minted(seasonId, id), reserved);
            total += box.minted(seasonId, id);
        }
        assertEq(total, ok ? count : 0);
        if (!ok) {
            assertEq(box.getStoredItems(purchase).length, 0);
            assertFalse(box.delivered(purchase));
            assertEq(furniture.totalSupply(), 0);
            return;
        }
        if (box.delivered(purchase)) {
            assertEq(box.getStoredItems(purchase).length, 0);
            assertEq(furniture.totalSupply(), count);
        } else {
            assertEq(box.getStoredItems(purchase), expected);
            assertEq(furniture.totalSupply(), 0);
            vm.prank(stranger);
            box.deliver(purchase);
            assertTrue(box.delivered(purchase));
            assertEq(furniture.totalSupply(), count);
        }
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(buyer, id), countOf(expected, id));
        }
    }

    // ----------------------------------------------------------------- storage footprint

    function test_SuccessfulOpenWritesNoStoredItemsAndFailureWritesExactlyTheRoll() public {
        uint256 failed = buy(10);
        uint256 delivered = buy(10);
        bytes32 randao = keccak256("footprint");
        bytes memory header = ready(delivered, randao);

        uint256[] memory expected = box.previewOpen(failed, randao);
        furniture.revokeMinter(address(box));
        vm.record();
        box.open(failed, header);
        (, bytes32[] memory writes) = vm.accesses(address(box));
        assertEq(vm.load(address(box), storedLengthSlot(failed)), bytes32(uint256(10)));
        for (uint256 j; j < 10; ++j) {
            assertEq(uint256(vm.load(address(box), storedElementSlot(failed, j))), expected[j]);
        }
        bool wroteLength;
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == storedLengthSlot(failed)) wroteLength = true;
        }
        assertTrue(wroteLength);
        // Nothing minted yet, so the box is re-authorized at once.
        furniture.grantMinter(address(box));

        vm.record();
        box.open(delivered, header);
        (, writes) = vm.accesses(address(box));
        assertTrue(box.delivered(delivered));
        bytes32 lengthSlot = storedLengthSlot(delivered);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != lengthSlot, "success path touched the stored-items length");
            for (uint256 j; j < 10; ++j) {
                assertTrue(writes[i] != storedElementSlot(delivered, j), "success path touched a stored element");
            }
        }
        assertEq(vm.load(address(box), lengthSlot), bytes32(0));

        // Delivery clears every stored slot; nothing lingers once the purchase is delivered.
        box.deliver(failed);
        assertEq(vm.load(address(box), storedLengthSlot(failed)), bytes32(0));
        for (uint256 j; j < 10; ++j) {
            assertEq(vm.load(address(box), storedElementSlot(failed, j)), bytes32(0));
        }
    }

    // ----------------------------------------------------------------- redirect targets

    function test_RedirectToNonReceiverContractsRevertsAndLeavesTheRollStored() public {
        DeafBuyer deaf = new DeafBuyer();
        token.mint(address(deaf), 10_000);
        vm.prank(address(deaf));
        token.approve(address(box), type(uint256).max);
        uint256 purchase = deaf.buy(box, seasonId, 10);
        bytes32 randao = keccak256("redirect targets");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        box.open(purchase, header);
        assertFalse(box.delivered(purchase));

        address[3] memory deadEnds = [address(box), address(furniture), address(deaf)];
        for (uint256 i; i < deadEnds.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, deadEnds[i]));
            deaf.deliverTo(box, purchase, deadEnds[i]);
            assertFalse(box.delivered(purchase));
            assertEq(box.getStoredItems(purchase), expected);
        }
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(address(box), id), 0);
            assertEq(furniture.balanceOf(address(furniture), id), 0);
        }
        Holder holder = new Holder();
        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, address(holder));
        deaf.deliverTo(box, purchase, address(holder));
        assertTrue(box.delivered(purchase));
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(address(holder), id), countOf(expected, id));
            assertEq(furniture.balanceOf(address(deaf), id), 0);
        }
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        box.deliver(purchase);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, purchase));
        deaf.deliverTo(box, purchase, buyer);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_OnlyTheBuyerRedirectsButAnyoneDelivers(bytes32 callerSeed, bytes32 toSeed) public {
        // Fresh, code-less, non-precompile addresses derived from the seeds; never the buyer.
        address caller = address(uint160(uint256(keccak256(abi.encode("caller", callerSeed)))));
        address to = address(uint160(uint256(keccak256(abi.encode("to", toSeed)))));
        if (caller == buyer) caller = stranger;
        uint256 purchase = buy(5);
        uint256 second = buy(5);
        bytes32 randao = keccak256(abi.encode("redirect", caller, to));
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        furniture.revokeMinter(address(box));
        box.open(purchase, header);
        uint256[] memory secondExpected = box.previewOpen(second, randao);
        box.open(second, header);
        // Nothing minted yet, so the box is re-authorized at once.
        furniture.grantMinter(address(box));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.NotBuyer.selector, purchase));
        box.deliverTo(purchase, to);
        assertFalse(box.delivered(purchase));
        vm.prank(buyer);
        box.deliverTo(purchase, to);
        assertTrue(box.delivered(purchase));
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(to, id), countOf(expected, id));
            if (to != buyer) assertEq(furniture.balanceOf(buyer, id), 0);
        }
        // The caller who could not redirect can still deliver the other stored purchase to the buyer.
        vm.prank(caller);
        box.deliver(second);
        assertTrue(box.delivered(second));
        assertEq(box.getStoredItems(second).length, 0);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 viaRedirect = to == buyer ? countOf(expected, id) : 0;
            assertEq(furniture.balanceOf(buyer, id), countOf(secondExpected, id) + viaRedirect);
        }
    }

    // ----------------------------------------------------------------- a roll is never lost

    /// @dev Once opened, time, blocks, season state, pause, vault and ownership changes do not touch the
    ///      stored roll; only the furniture's minter role gates delivery.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_StoredRollSurvivesAnyDelayAndSeasonChanges(uint64 blocks, uint64 seconds_, bytes32 randao)
        public
    {
        uint256 purchase = buy(10);
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        furniture.revokeMinter(address(box));
        box.open(purchase, header);
        assertEq(box.getStoredItems(purchase), expected);
        vm.roll(block.number + bound(blocks, 0, 10_000_000));
        vm.warp(block.timestamp + bound(seconds_, 0, 10 * 365 days));
        box.closeSeason(seasonId);
        box.setPaused(true);
        box.setVault(stranger);
        box.transferOwnership(stranger);
        vm.prank(stranger);
        box.acceptOwnership();
        // Another purchase's expiry does not touch this one.
        assertEq(box.getStoredItems(purchase), expected);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(box)));
        box.deliver(purchase);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase), expected);
        // Nothing was ever minted, so the furniture owner can still re-authorize the box at once.
        furniture.grantMinter(address(box));
        vm.prank(stranger);
        box.deliver(purchase);
        assertTrue(box.delivered(purchase));
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(furniture.balanceOf(buyer, id), countOf(expected, id));
        }
        assertEq(token.balanceOf(address(box)), 0);
    }

    function test_ExpiryOnlyAppliesToUnopenedPurchasesEvenWhenDeliveryIsPending() public {
        uint256 opened = buy(10);
        uint256 neverOpened = buy(10);
        bytes32 randao = keccak256("pending through expiry");
        bytes memory header = ready(opened, randao);
        uint256[] memory expected = box.previewOpen(opened, randao);
        bool nonFallback;
        for (uint256 i; i < expected.length; ++i) {
            if (expected[i] != 1) nonFallback = true;
        }
        assertTrue(nonFallback, "fixture must roll something other than the fallback");
        furniture.revokeMinter(address(box));
        box.open(opened, header);
        vm.roll(target(opened) + 257);
        assertEq(box.getStoredItems(opened), expected, "expiry never rewrites a stored roll");
        vm.expectRevert(abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, opened));
        box.previewOpen(opened, randao);
        uint256[] memory fallbacks = box.previewOpen(neverOpened, randao);
        for (uint256 i; i < fallbacks.length; ++i) {
            assertEq(fallbacks[i], 1);
        }
        box.open(neverOpened, "");
        assertEq(box.getStoredItems(neverOpened), fallbacks);
        furniture.grantMinter(address(box));
        box.deliver(opened);
        box.deliver(neverOpened);
        assertEq(furniture.balanceOf(buyer, 1), countOf(expected, 1) + 10);
        assertEq(furniture.balanceOf(buyer, 2), countOf(expected, 2));
        assertEq(furniture.balanceOf(buyer, 3), countOf(expected, 3));
    }

    // ----------------------------------------------------------------- the "nothing minted" rule

    /// @dev The immediate-grant path is keyed on supply, not on sales: stored, undelivered rolls do not
    ///      close it. This is the behavior the brief specifies; it is also recorded in the findings file.
    function test_ImmediateGrantStaysOpenWhileOnlyUndeliveredRollsExist() public {
        uint256 purchase = buy(10);
        furniture.revokeMinter(address(box));
        box.open(purchase, ready(purchase, keccak256("undelivered only")));
        assertEq(box.getStoredItems(purchase).length, 10);
        assertEq(furniture.totalSupply(), 0);
        furniture.grantMinter(stranger);
        assertTrue(furniture.minters(stranger));
        assertEq(furniture.pendingMinters(stranger), 0);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 3;
        amounts[0] = 1;
        vm.prank(stranger);
        furniture.mintBatch(stranger, ids, amounts);
        // From the first real mint on, every further grant waits.
        furniture.grantMinter(address(box));
        assertFalse(furniture.minters(address(box)));
        assertEq(furniture.pendingMinters(address(box)), block.timestamp + 7 days);
    }

    function test_ZeroAmountMintsLeaveSupplyZeroAndGrantsImmediate() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        furniture.grantMinter(stranger);
        vm.prank(stranger);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(), 0);
        assertFalse(furniture.exists(1));
        furniture.grantMinter(buyer);
        assertTrue(furniture.minters(buyer));
        amounts[0] = 1;
        vm.prank(buyer);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.totalSupply(), 1);
        furniture.grantMinter(vault);
        assertFalse(furniture.minters(vault));
        assertEq(furniture.pendingMinters(vault), block.timestamp + 7 days);
    }

    /// @dev Supply can never return to zero: there is no burn and transfers to the zero address revert,
    ///      so once the delay applies it applies forever.
    function test_SupplyCannotReturnToZeroSoTheDelayIsPermanent() public {
        uint256 purchase = buy(1);
        box.open(purchase, ready(purchase, keccak256("permanent")));
        assertEq(furniture.totalSupply(), 1);
        uint256 id;
        for (id = 1; id <= 3; ++id) {
            if (furniture.balanceOf(buyer, id) == 1) break;
        }
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0)));
        furniture.safeTransferFrom(buyer, address(0), id, 1, "");
        (bool ok,) = address(furniture).call(abi.encodeWithSignature("burn(address,uint256,uint256)", buyer, id, 1));
        assertFalse(ok);
        (ok,) = address(furniture)
            .call(
                abi.encodeWithSignature(
                    "burnBatch(address,uint256[],uint256[])", buyer, new uint256[](1), new uint256[](1)
                )
            );
        assertFalse(ok);
        assertEq(furniture.totalSupply(), 1);
        furniture.grantMinter(stranger);
        assertFalse(furniture.minters(stranger));
        assertGt(furniture.pendingMinters(stranger), 0);
    }

    /// @dev Exact boundary: activation reverts one second before the deadline and succeeds at it.
    function testFuzz_ActivationBoundaryIsExact(uint32 proposedOffset) public {
        uint256 purchase = buy(1);
        box.open(purchase, ready(purchase, keccak256("boundary")));
        vm.warp(block.timestamp + proposedOffset);
        furniture.grantMinter(stranger);
        uint256 activatesAt = furniture.pendingMinters(stranger);
        assertEq(activatesAt, block.timestamp + 7 days);
        vm.warp(activatesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, stranger, activatesAt));
        furniture.activateMinter(stranger);
        vm.warp(activatesAt);
        vm.prank(buyer);
        furniture.activateMinter(stranger);
        assertTrue(furniture.minters(stranger));
        assertEq(furniture.pendingMinters(stranger), 0);
    }
}
