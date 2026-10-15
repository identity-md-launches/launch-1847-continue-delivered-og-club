// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";

contract Holder is ERC1155Holder {}

/// @dev Random mints, transfers, approvals and owner actions. The owner is a separate account that
///      repeatedly tries to move, burn or seize tokens and must always fail.
contract FurnitureHandler is Test {
    OGClubFurniture public furniture;
    address public owner;
    address[] public holders;
    uint256 public constant ITEMS = 6;

    mapping(address holder => mapping(uint256 id => uint256 amount)) public ghostBalance;
    mapping(uint256 id => uint256 amount) public ghostSupply;
    uint256 public ghostTotal;
    bool public ghostFrozen;
    string public frozenURI;
    uint256 public seizureAttempts;
    uint256 public transfers;
    uint256 public operatorTransfers;

    constructor(OGClubFurniture furniture_, address owner_) {
        furniture = furniture_;
        owner = owner_;
        for (uint256 i; i < 3; ++i) {
            holders.push(address(new Holder()));
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function mint(uint8 toSeed, uint8 idSeed, uint8 amountSeed, uint8 secondIdSeed) external {
        address to = holders[toSeed % holders.length];
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1 + idSeed % ITEMS;
        ids[1] = 1 + secondIdSeed % ITEMS; // may repeat ids[0]
        amounts[0] = bound(amountSeed, 1, 20);
        amounts[1] = bound(uint256(amountSeed) * 7, 0, 20); // zero amounts are legal in a batch
        furniture.mintBatch(to, ids, amounts); // the handler is the authorized minter
        for (uint256 i; i < 2; ++i) {
            ghostBalance[to][ids[i]] += amounts[i];
            ghostSupply[ids[i]] += amounts[i];
            ghostTotal += amounts[i];
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint8 idSeed, uint8 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 id = 1 + idSeed % ITEMS;
        uint256 balance = furniture.balanceOf(from, id);
        uint256 amount = bound(amountSeed, 0, balance + 1);
        vm.prank(from);
        if (amount > balance) {
            vm.expectRevert();
            furniture.safeTransferFrom(from, to, id, amount, "");
            return;
        }
        furniture.safeTransferFrom(from, to, id, amount, "");
        ghostBalance[from][id] -= amount;
        ghostBalance[to][id] += amount;
        ++transfers;
    }

    function operatorBatchTransfer(uint8 fromSeed, uint8 operatorSeed, uint8 toSeed, uint8 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        address operator = holders[operatorSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256[] memory ids = new uint256[](ITEMS);
        uint256[] memory amounts = new uint256[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            ids[i] = i + 1;
            amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0, furniture.balanceOf(from, i + 1));
        }
        if (operator != from && !furniture.isApprovedForAll(from, operator)) {
            vm.prank(operator);
            vm.expectRevert();
            furniture.safeBatchTransferFrom(from, to, ids, amounts, "");
            vm.prank(from);
            furniture.setApprovalForAll(operator, true);
        }
        vm.prank(operator);
        furniture.safeBatchTransferFrom(from, to, ids, amounts, "");
        for (uint256 i; i < ITEMS; ++i) {
            ghostBalance[from][ids[i]] -= amounts[i];
            ghostBalance[to][ids[i]] += amounts[i];
        }
        ++operatorTransfers;
    }

    function revokeApproval(uint8 fromSeed, uint8 operatorSeed) external {
        address from = holders[fromSeed % holders.length];
        address operator = holders[operatorSeed % holders.length];
        vm.prank(from);
        furniture.setApprovalForAll(operator, false);
        assertFalse(furniture.isApprovedForAll(from, operator));
    }

    function ownerTriesToSeize(uint8 victimSeed, uint8 idSeed, uint8 how) external {
        address victim = holders[victimSeed % holders.length];
        uint256 id = 1 + idSeed % ITEMS;
        uint256 amount = furniture.balanceOf(victim, id);
        if (amount == 0) amount = 1;
        bytes memory call_;
        uint256 w = how % 4;
        if (w == 0) {
            call_ = abi.encodeCall(furniture.safeTransferFrom, (victim, owner, id, amount, ""));
        } else if (w == 1) {
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amounts = new uint256[](1);
            ids[0] = id;
            amounts[0] = amount;
            call_ = abi.encodeCall(furniture.safeBatchTransferFrom, (victim, owner, ids, amounts, ""));
        } else if (w == 2) {
            call_ = abi.encodeWithSignature("burn(address,uint256,uint256)", victim, id, amount);
        } else {
            call_ = abi.encodeWithSignature(
                "burnBatch(address,uint256[],uint256[])", victim, new uint256[](1), new uint256[](1)
            );
        }
        vm.prank(owner);
        (bool ok,) = address(furniture).call(call_);
        assertFalse(ok, "owner moved or burned a holder's tokens");
        ++seizureAttempts;
    }

    function ownerMetadata(uint8 which, string calldata uri_) external {
        vm.startPrank(owner);
        if (which % 3 == 0) {
            if (ghostFrozen) {
                vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
                furniture.setBaseURI(uri_);
            } else {
                furniture.setBaseURI(uri_);
                assertEq(furniture.baseURI(), uri_);
            }
        } else if (which % 3 == 1) {
            if (ghostFrozen) {
                vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
                furniture.freezeMetadata();
            } else {
                furniture.freezeMetadata();
                ghostFrozen = true;
                frozenURI = furniture.baseURI();
            }
        } else {
            uint96 bps = uint96(bound(uint256(keccak256(bytes(uri_))), 0, 1200));
            if (bps > 1000) {
                vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.RoyaltyTooHigh.selector, bps));
                furniture.setRoyalty(owner, bps);
            } else {
                furniture.setRoyalty(owner, bps);
                (address receiver, uint256 royalty) = furniture.royaltyInfo(1, 10_000);
                assertEq(receiver, owner);
                assertEq(royalty, bps);
            }
        }
        vm.stopPrank();
    }

    function strangerCannotAdminister(uint8 which, uint8 whoSeed) external {
        address who = holders[whoSeed % holders.length];
        bytes memory call_;
        uint256 w = which % 7;
        if (w == 0) call_ = abi.encodeCall(furniture.grantMinter, (who));
        else if (w == 1) call_ = abi.encodeCall(furniture.setBaseURI, ("x"));
        else if (w == 2) call_ = abi.encodeCall(furniture.freezeMetadata, ());
        else if (w == 3) call_ = abi.encodeCall(furniture.setRoyalty, (who, 1));
        else if (w == 4) call_ = abi.encodeCall(furniture.transferOwnership, (who));
        else if (w == 5) call_ = abi.encodeCall(furniture.cancelMinter, (who));
        else call_ = abi.encodeCall(furniture.revokeMinter, (who));
        vm.prank(who);
        (bool ok, bytes memory reason) = address(furniture).call(call_);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        // A holder is never a minter either.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.prank(who);
        (ok, reason) = address(furniture).call(abi.encodeCall(furniture.mintBatch, (who, ids, amounts)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, who));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 80
contract FurnitureInvariantTest is Test {
    OGClubFurniture internal furniture;
    FurnitureHandler internal handler;
    address internal owner = makeAddr("furniture owner");

    function setUp() public {
        furniture = new OGClubFurniture(owner, owner);
        handler = new FurnitureHandler(furniture, owner);
        vm.prank(owner);
        furniture.grantMinter(address(handler));
        handler.mint(0, 0, 5, 1);
        handler.ownerTriesToSeize(0, 0, 0);
        targetContract(address(handler));
    }

    function invariant_BalancesAndSupplyMatchGhosts() public view {
        uint256 total;
        for (uint256 id = 1; id <= handler.ITEMS(); ++id) {
            uint256 sum;
            for (uint256 i; i < handler.holderCount(); ++i) {
                address holder = handler.holders(i);
                assertEq(furniture.balanceOf(holder, id), handler.ghostBalance(holder, id));
                sum += furniture.balanceOf(holder, id);
            }
            assertEq(furniture.totalSupply(id), handler.ghostSupply(id));
            assertEq(sum, furniture.totalSupply(id), "tokens exist outside the holders");
            assertEq(furniture.exists(id), sum != 0);
            total += sum;
        }
        assertEq(furniture.totalSupply(), total);
        assertEq(total, handler.ghostTotal());
    }

    function invariant_OwnerNeverHoldsOrDestroysAnything() public view {
        for (uint256 id; id <= handler.ITEMS() + 1; ++id) {
            assertEq(furniture.balanceOf(owner, id), 0);
            assertEq(furniture.balanceOf(address(handler), id), 0);
        }
        assertGt(handler.seizureAttempts(), 0);
        assertEq(furniture.owner(), owner);
    }

    function invariant_FrozenMetadataNeverChangesAndRoyaltyIsBounded() public view {
        assertEq(furniture.metadataFrozen(), handler.ghostFrozen());
        if (handler.ghostFrozen()) assertEq(furniture.baseURI(), handler.frozenURI());
        (, uint256 royalty) = furniture.royaltyInfo(1, 10_000);
        assertLe(royalty, 1000);
        assertEq(furniture.uri(7), string.concat(furniture.baseURI(), "7.json"));
    }
}
