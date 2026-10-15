// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HostileDeliveryBuyer} from "./helpers/Adversaries.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

/// @dev The gas a caller attaches must never choose between delivery and a stored roll. A short caller
///      reverts before any state change; every succeeding open forwards the full mint budget.
contract OpenGasTest is BoxTestBase {
    event Delivered(uint256 indexed purchaseId, address indexed to);
    event DeliveryFailed(uint256 indexed purchaseId);

    function _openCall(uint256 purchase, bytes memory header, uint256 gas)
        internal
        returns (bool ok, bytes memory data)
    {
        return address(box).call{gas: gas}(abi.encodeCall(box.open, (purchase, header)));
    }

    /// @dev Lowest gas limit at which open succeeds, like eth_estimateGas; state is restored after every attempt.
    function _lowestSucceedingGas(uint256 purchase, bytes memory header) internal returns (uint256 hi) {
        uint256 lo;
        hi = 5_000_000;
        uint256 snapshot = vm.snapshotState();
        (bool ok,) = _openCall(purchase, header, hi);
        assertTrue(ok, "ample gas opens");
        assertTrue(vm.revertToState(snapshot));
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            snapshot = vm.snapshotState();
            (ok,) = _openCall(purchase, header, mid);
            assertTrue(vm.revertToState(snapshot));
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _assertUntouched(uint256 purchase) internal view {
        (,,,, bool opened) = box.purchases(purchase);
        assertFalse(opened);
        assertFalse(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(box.minted(seasonId, id), 0);
        }
        assertEq(furniture.totalSupply(), 0);
    }

    function test_GasConstantsArePublishedAndConsistent() public view {
        assertEq(box.OPEN_DELIVERY_GAS(), box.OPEN_MINT_GAS_LIMIT() + box.DELIVERY_RESERVE_GAS());
        assertEq(box.OPEN_MINT_GAS_LIMIT(), 1_000_000);
        assertEq(box.DELIVERY_RESERVE_GAS(), 300_000);
    }

    /// @dev A wallet sending the measured gas plus a generous buffer, or a stranger attaching 1.0-1.5x of it,
    ///      used to land a healthy EOA buyer on the DeliveryFailed path. Now the open reverts untouched.
    function test_ShortGasOpenRevertsInsteadOfRecordingDeliveryFailure() public {
        uint256 purchase = buy(10);
        bytes memory header = ready(purchase, keccak256("gas estimate"));

        uint256 snapshot = vm.snapshotState();
        uint256 before = gasleft();
        box.open(purchase, header);
        uint256 used = before - gasleft();
        assertTrue(box.delivered(purchase));
        assertTrue(vm.revertToState(snapshot));

        uint256[3] memory limits = [used, used * 3 / 2, 600_000];
        for (uint256 i; i < limits.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory data) = _openCall(purchase, header, limits[i]);
            assertFalse(ok, "short gas must not open");
            // The roll itself fits in these limits, so the revert is the explicit precondition, not an OOG.
            assertEq(bytes4(data), OGClubBox.InsufficientGas.selector);
            (uint256 required, uint256 available) = abi.decode(_slice(data), (uint256, uint256));
            assertEq(required, box.OPEN_DELIVERY_GAS());
            assertLt(available, required);
            _assertUntouched(purchase);
        }

        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, buyer);
        box.open(purchase, header);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
    }

    /// @dev The lowest gas at which open succeeds (what estimation returns) always delivers and stores nothing.
    function testFuzz_LowestSucceedingGasDeliversAndStoresNothing(uint8 count, bytes32 randao) public {
        count = uint8(bound(count, 1, 10));
        uint256 purchase = buy(count);
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        uint256 lowest = _lowestSucceedingGas(purchase, header);
        assertGt(lowest, box.OPEN_DELIVERY_GAS());

        vm.prank(stranger);
        (bool ok,) = _openCall(purchase, header, lowest - 1);
        assertFalse(ok);
        _assertUntouched(purchase);

        vm.expectEmit(true, true, false, true, address(box));
        emit Delivered(purchase, buyer);
        vm.prank(stranger);
        (ok,) = _openCall(purchase, header, lowest);
        assertTrue(ok);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 received;
            for (uint256 i; i < expected.length; ++i) {
                if (expected[i] == id) ++received;
            }
            assertEq(furniture.balanceOf(buyer, id), received);
        }
        assertEq(furniture.totalSupply(), count);
    }

    /// @dev At the exact gas boundary a cooperative receiver needs, a receiver that burns the whole mint budget or
    ///      returns a huge revert payload still leaves enough reserve to store ten distinct IDs.
    function test_ReserveSavesTenDistinctItemsAtLowestDeliveryGas() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](32);
        for (uint256 i; i < entries.length; ++i) {
            entries[i] = OGClubBox.Entry(i + 1, i == 0 ? 0 : 2, 1, 0);
        }
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        HostileDeliveryBuyer receiver = new HostileDeliveryBuyer();
        token.mint(address(receiver), 100);
        uint256 purchase = receiver.buy(box, token, seasonId, 10);
        bytes32 randao = _distinctRandao(purchase);
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        uint256 lowest = _lowestSucceedingGas(purchase, header);

        for (uint8 mode = 1; mode <= 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            receiver.setMode(mode);
            vm.expectEmit(true, false, false, true, address(box));
            emit DeliveryFailed(purchase);
            (bool ok,) = _openCall(purchase, header, lowest);
            assertTrue(ok, "reserve must store the roll at the delivery gas boundary");
            (,,,, bool opened) = box.purchases(purchase);
            assertTrue(opened);
            assertFalse(box.delivered(purchase));
            assertEq(box.getStoredItems(purchase), expected);
            assertEq(furniture.totalSupply(), 0);
            receiver.deliverTo(box, purchase, buyer);
            assertTrue(box.delivered(purchase));
            for (uint256 id = 1; id <= 32; ++id) {
                assertEq(furniture.balanceOf(buyer, id), box.minted(seasonId, id));
            }
            assertTrue(vm.revertToState(snapshot));
        }

        receiver.setMode(0);
        (bool delivered,) = _openCall(purchase, header, lowest);
        assertTrue(delivered);
        assertTrue(box.delivered(purchase));
        assertEq(box.getStoredItems(purchase).length, 0);
    }

    function _distinctRandao(uint256 purchase) internal view returns (bytes32 randao) {
        for (uint256 n; n < 10_000; ++n) {
            randao = keccak256(abi.encode("distinct gas boundary", n));
            uint256 seen;
            bool distinct = true;
            for (uint256 i; i < 10; ++i) {
                uint256 seed = uint256(keccak256(abi.encode(randao, block.chainid, address(box), purchase, i)));
                uint256 id = i == 9 ? 2 + seed % 31 : 1 + seed % 32;
                if (seen & (1 << id) != 0) {
                    distinct = false;
                    break;
                }
                seen |= 1 << id;
            }
            if (distinct) return randao;
        }
        revert("no distinct roll found");
    }

    function _slice(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
