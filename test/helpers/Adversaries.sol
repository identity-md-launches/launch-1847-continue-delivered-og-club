// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {OGClubBox} from "../../src/OGClubBox.sol";

contract FeeToken is ERC20 {
    address public taxedRecipient;

    constructor(address recipient) ERC20("Fee token", "FEE") {
        taxedRecipient = recipient;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == taxedRecipient && value != 0) {
            uint256 fee = value / 100 + 1;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FalseReturnToken is ERC20 {
    constructor() ERC20("False token", "FALSE") {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract ReentrantToken is ERC20 {
    OGClubBox public box;
    uint256 public season;
    bool public buySucceeded;
    bool public openSucceeded;
    uint256 public attempts;

    constructor() ERC20("Callback token", "CALLBACK") {}

    function configure(OGClubBox box_, uint256 season_) external {
        box = box_;
        season = season_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        ++attempts;
        (buySucceeded,) = address(box).call(abi.encodeCall(box.buy, (season, 1)));
        (openSucceeded,) = address(box).call(abi.encodeCall(box.open, (box.purchaseCount(), bytes(""))));
        return super.transferFrom(from, to, amount);
    }
}

contract ReentrantBuyer is ERC1155Holder {
    OGClubBox public box;
    IERC20 public token;
    uint256 public season;
    uint256 public purchaseId;
    uint256 public otherPurchaseId;
    bytes public header;
    uint256 public callbacks;
    bool public sawOpened;
    bool public openSucceeded;
    bool public otherOpenSucceeded;
    bool public buySucceeded;
    bytes4 public openError;
    bytes4 public buyError;
    bool public reject;
    bool public sawDelivered;
    bool public deliverSucceeded;
    bool public deliverToSucceeded;
    bool public otherDeliverSucceeded;
    bytes4 public deliverError;
    bytes4 public deliverToError;

    constructor(OGClubBox box_, IERC20 token_, uint256 season_) {
        box = box_;
        token = token_;
        season = season_;
        token.approve(address(box), type(uint256).max);
    }

    function buy(uint256 count) external returns (uint256) {
        purchaseId = box.buy(season, count);
        otherPurchaseId = box.buy(season, 1);
        return purchaseId;
    }

    function configure(bytes calldata header_, bool reject_) external {
        header = header_;
        reject = reject_;
    }

    function _callback() internal {
        require(!reject, "test receiver rejects");
        ++callbacks;
        (,,,, sawOpened) = box.purchases(purchaseId);
        sawDelivered = box.delivered(purchaseId);
        bytes memory reason;
        (deliverSucceeded, reason) = address(box).call(abi.encodeCall(box.deliver, (purchaseId)));
        deliverError = bytes4(reason);
        (deliverToSucceeded, reason) = address(box).call(abi.encodeCall(box.deliverTo, (purchaseId, address(this))));
        deliverToError = bytes4(reason);
        (otherDeliverSucceeded,) = address(box).call(abi.encodeCall(box.deliver, (otherPurchaseId)));
        (openSucceeded, reason) = address(box).call(abi.encodeCall(box.open, (purchaseId, header)));
        openError = bytes4(reason);
        (otherOpenSucceeded,) = address(box).call(abi.encodeCall(box.open, (otherPurchaseId, header)));
        (buySucceeded, reason) = address(box).call(abi.encodeCall(box.buy, (season, 1)));
        buyError = bytes4(reason);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        _callback();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        override
        returns (bytes4)
    {
        _callback();
        return this.onERC1155BatchReceived.selector;
    }
}

/// @dev Simulates both all-gas consumption and a large revert payload from an untrusted receiver.
contract HostileDeliveryBuyer is ERC1155Holder {
    uint8 public mode;

    function buy(OGClubBox box, IERC20 token, uint256 season, uint256 count) external returns (uint256) {
        token.approve(address(box), type(uint256).max);
        return box.buy(season, count);
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function deliverTo(OGClubBox box, uint256 purchase, address to) external {
        box.deliverTo(purchase, to);
    }

    function _reject() internal view {
        if (mode == 1) {
            assembly ("memory-safe") { invalid() }
        } else if (mode == 2) {
            // A payload large enough to exercise returndata handling, bounded by forwarded gas.
            assembly { revert(0, 0x40000) }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public view override returns (bytes4) {
        _reject();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        _reject();
        return this.onERC1155BatchReceived.selector;
    }
}

/// @dev Rejects initial delivery, then accepts retries based on the box's delivery flag.
///      A counter increment inside a reverting callback would itself roll back.
contract RetryOnlyBuyer is ERC1155Holder {
    OGClubBox public box;
    uint256 public purchase;
    uint256 public accepted;

    function buy(OGClubBox box_, IERC20 token, uint256 season, uint256 count) external returns (uint256) {
        box = box_;
        token.approve(address(box), type(uint256).max);
        purchase = box.buy(season, count);
        return purchase;
    }

    function _receive() internal {
        require(box.delivered(purchase), "reject initial delivery");
        ++accepted;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        _receive();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        override
        returns (bytes4)
    {
        _receive();
        return this.onERC1155BatchReceived.selector;
    }
}
