// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {OGClubBox} from "../src/OGClubBox.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Stateful actions use real buys and mints; ghost counters independently account for outcomes.
contract BoxHandler is Test, ERC1155Holder {
    OGClubBox public box;
    OGClubFurniture public furniture;
    MockOG public token;
    address public owner;
    uint256 public paid;
    uint256 public burned;
    uint256 public itemsOpened;
    uint256 public previewChecks;
    uint256 public replayChecks;
    uint256 public deliveryReplayChecks;
    uint256 public deliveryFailures;
    uint256 public itemsDelivered;
    bool public rejectDelivery;
    address public redirectedRecipient = makeAddr("delivery recipient");
    mapping(uint256 => uint256) public deliveryCount;
    mapping(uint256 => bytes32) public recordedRoll;
    mapping(uint256 => uint256) public openCount;
    mapping(uint256 => bool) internal hasRandao;
    mapping(uint256 => bytes32) internal randaoByBlock;

    constructor(OGClubBox box_, OGClubFurniture furniture_, MockOG token_, address owner_) {
        box = box_;
        furniture = furniture_;
        token = token_;
        owner = owner_;
        token.approve(address(box), type(uint256).max);
    }

    function purchase(uint8 countInput, uint8 seasonInput) external {
        uint256 season = uint256(seasonInput) % 2 + 1;
        OGClubBox.Season memory terms = box.getSeason(season);
        if (box.paused() || terms.closed) return;
        uint256 count = bound(countInput, 1, 10);
        uint256 total = terms.price * count;
        uint256 id = box.buy(season, count);
        assertEq(openCount[id], 0);
        paid += total;
        burned += total * terms.burnBps / 10_000;
    }

    function advance(uint16 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 300));
    }

    function pause(bool value) external {
        vm.prank(owner);
        box.setPaused(value);
    }

    function reveal(uint256 selector, bytes32 entropy) external {
        if (box.purchaseCount() == 0) return;
        uint256 id = selector % box.purchaseCount() + 1;
        (address buyer, uint256 season, uint256 count, uint256 targetBlock, bool opened) = box.purchases(id);
        if (opened) {
            (bool success, bytes memory reason) = address(box).call(abi.encodeCall(box.open, (id, bytes(""))));
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(OGClubBox.AlreadyOpened.selector, id));
            ++replayChecks;
            return;
        }
        if (block.number <= targetBlock) vm.roll(targetBlock + 1);
        if (!hasRandao[targetBlock]) {
            hasRandao[targetBlock] = true;
            randaoByBlock[targetBlock] = entropy;
        }
        bytes32 randao = randaoByBlock[targetBlock];
        bytes memory header = HeaderBuilder.header(targetBlock, randao, 7);
        if (block.number - targetBlock <= 256) vm.setBlockhash(targetBlock, keccak256(header));
        uint256[] memory preview = box.previewOpen(id, randao);
        uint256[3] memory beforeBalances;
        for (uint256 i; i < 3; ++i) {
            beforeBalances[i] = furniture.balanceOf(buyer, i + 1);
        }
        box.open(id, header);
        recordedRoll[id] = keccak256(abi.encode(preview));
        if (box.delivered(id)) {
            ++deliveryCount[id];
            itemsDelivered += count;
            assertEq(box.getStoredItems(id).length, 0);
        } else {
            ++deliveryFailures;
            assertEq(box.getStoredItems(id), preview);
        }
        for (uint256 i; i < 3; ++i) {
            uint256 expected;
            for (uint256 j; j < preview.length; ++j) {
                if (preview[j] == i + 1) ++expected;
            }
            assertEq(
                furniture.balanceOf(buyer, i + 1),
                beforeBalances[i] + (box.delivered(id) ? expected : 0),
                "preview/open disagreement"
            );
        }
        ++previewChecks;
        ++openCount[id];
        itemsOpened += count;
        assertEq(preview.length, count);
        assertLe(box.minted(season, 2), 4);
        assertLe(box.minted(season, 3), 3);
    }

    function setRejectDelivery(bool value) external {
        rejectDelivery = value;
    }

    function retryDelivery(uint256 selector, bool redirect) external {
        if (box.purchaseCount() == 0) return;
        uint256 id = selector % box.purchaseCount() + 1;
        (,, uint256 count,, bool opened) = box.purchases(id);
        bool wasDelivered = box.delivered(id);
        uint256[] memory stored = box.getStoredItems(id);
        address to = redirect ? redirectedRecipient : address(this);
        uint256[3] memory balances;
        for (uint256 item = 1; item <= 3; ++item) {
            balances[item - 1] = furniture.balanceOf(to, item);
        }
        bytes memory call_ = redirect ? abi.encodeCall(box.deliverTo, (id, to)) : abi.encodeCall(box.deliver, (id));
        // Permissionless deliver is exercised by a third party; deliverTo must come from the buyer.
        if (!redirect) vm.prank(makeAddr("delivery relayer"));
        (bool ok, bytes memory reason) = address(box).call(call_);
        if (!opened) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubBox.NotOpened.selector, id));
        } else if (wasDelivered) {
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(OGClubBox.AlreadyDelivered.selector, id));
            ++deliveryReplayChecks;
        } else if (rejectDelivery && !redirect) {
            assertFalse(ok);
            assertFalse(box.delivered(id));
            assertEq(box.getStoredItems(id), stored);
            ++deliveryFailures;
        } else {
            assertTrue(ok);
            assertEq(stored.length, count);
            assertEq(keccak256(abi.encode(stored)), recordedRoll[id]);
            assertTrue(box.delivered(id));
            assertEq(box.getStoredItems(id).length, 0);
            ++deliveryCount[id];
            itemsDelivered += count;
        }
        for (uint256 item = 1; item <= 3; ++item) {
            uint256 received;
            if (ok) {
                for (uint256 i; i < stored.length; ++i) {
                    if (stored[i] == item) ++received;
                }
            }
            assertEq(furniture.balanceOf(to, item), balances[item - 1] + received);
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public view override returns (bytes4) {
        require(!rejectDelivery, "receiver rejects");
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        require(!rejectDelivery, "receiver rejects");
        return this.onERC1155BatchReceived.selector;
    }
}

contract BoxInvariantTest is BoxTestBase {
    BoxHandler internal handler;

    function setUp() public override {
        super.setUp();
        box.createSeason(77, 1000, 100_000, 10_000, 1, defaultEntries());
        handler = new BoxHandler(box, furniture, token, address(this));
        token.mint(address(handler), 1_000_000 ether);
        // Start with an actual purchase and reveal, so the invariants are never vacuous.
        handler.purchase(10, 0);
        handler.reveal(0, keccak256("initial invariant reveal"));
        handler.reveal(0, bytes32(0));
        handler.retryDelivery(0, false); // Already delivered: replay must fail.
        handler.setRejectDelivery(true);
        handler.purchase(10, 1);
        handler.reveal(1, keccak256("stored invariant reveal"));
        handler.retryDelivery(1, false); // Receiver still rejects; storage must survive.
        handler.purchase(10, 0);
        handler.reveal(2, keccak256("redirected invariant reveal"));
        handler.retryDelivery(2, true); // Successful redirect, leaving purchase 2 stored.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BoxHandler.purchase.selector;
        selectors[1] = BoxHandler.advance.selector;
        selectors[2] = BoxHandler.pause.selector;
        selectors[3] = BoxHandler.reveal.selector;
        selectors[4] = BoxHandler.setRejectDelivery.selector;
        selectors[5] = BoxHandler.retryDelivery.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_PaymentsAreConservedWithoutBoxCustody() public view {
        assertEq(token.balanceOf(address(box)), 0);
        assertEq(token.balanceOf(box.BURN_ADDRESS()), handler.burned());
        assertEq(token.balanceOf(vault), handler.paid() - handler.burned());
        assertEq(token.balanceOf(address(handler)), 1_000_000 ether - handler.paid());
    }

    function invariant_CapsAndDeliveredSupplyPlusStoredItemsMatchPerSeasonMints() public view {
        uint256 total;
        uint256 storedTotal;
        uint256[4] memory storedPerItem;
        for (uint256 purchase = 1; purchase <= box.purchaseCount(); ++purchase) {
            uint256[] memory stored = box.getStoredItems(purchase);
            if (stored.length != 0) {
                assertFalse(box.delivered(purchase));
                assertEq(keccak256(abi.encode(stored)), handler.recordedRoll(purchase));
            }
            for (uint256 i; i < stored.length; ++i) {
                ++storedPerItem[stored[i]];
            }
            storedTotal += stored.length;
        }
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 combined;
            for (uint256 season = 1; season <= 2; ++season) {
                uint256 minted = box.minted(season, id);
                if (id == 2) assertLe(minted, 4);
                if (id == 3) assertLe(minted, 3);
                combined += minted;
            }
            assertEq(combined, furniture.totalSupply(id) + storedPerItem[id]);
            assertEq(
                furniture.totalSupply(id),
                furniture.balanceOf(address(handler), id) + furniture.balanceOf(handler.redirectedRecipient(), id)
            );
            total += combined;
        }
        assertEq(total, handler.itemsOpened());
        assertEq(total, furniture.totalSupply() + storedTotal);
        assertEq(furniture.totalSupply(), handler.itemsDelivered());
    }

    function invariant_EachPurchaseOpenedOnceAndEveryOpenMatchedPreview() public view {
        uint256 openPurchases;
        uint256 openItems;
        for (uint256 id = 1; id <= box.purchaseCount(); ++id) {
            (,, uint256 count,, bool opened) = box.purchases(id);
            assertEq(handler.openCount(id), opened ? 1 : 0);
            bool delivered = box.delivered(id);
            assertEq(handler.deliveryCount(id), delivered ? 1 : 0);
            if (delivered) assertTrue(opened);
            assertEq(box.getStoredItems(id).length, opened && !delivered ? count : 0);
            if (opened) {
                ++openPurchases;
                openItems += count;
            }
        }
        assertEq(openPurchases, handler.previewChecks());
        assertEq(openItems, handler.itemsOpened());
        assertGt(handler.previewChecks(), 0);
        assertGt(handler.replayChecks(), 0);
        assertGt(handler.deliveryReplayChecks(), 0);
        assertGt(handler.deliveryFailures(), 0);
    }
}
