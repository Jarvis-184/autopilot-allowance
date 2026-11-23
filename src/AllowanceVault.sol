// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @title AllowanceVault — a personal recurring-payment vault (destination side).
/// @notice The owner deposits funds once, sets one allowance plan (recipient,
///         amount, interval, start), and forgets it. The AllowanceAutopilot
///         reactive contract watches this vault's events and fires `pay()` on
///         schedule through the Reactive Network callback proxy. Only that
///         autopilot, delivered by the chain's callback proxy, can move funds,
///         and only to the plan's recipient, only the plan's amount.
contract AllowanceVault is AbstractCallback {
    event PlanSet(address indexed recipient, uint256 amount, uint256 intervalSeconds, uint256 startAt);
    event PlanCancelled(address indexed recipient);
    event Paid(address indexed recipient, uint256 amount, uint256 paidAt);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    address public owner;

    address public recipient;
    uint256 public amount;
    uint256 public intervalSeconds;
    uint256 public startAt;
    bool public planActive;
    uint256 public payoutCount;

    modifier onlyOwner() {
        require(msg.sender == owner, "AllowanceVault: not owner");
        _;
    }

    /// @param callbackProxy_ The chain's Reactive Network callback proxy.
    /// @param autopilot_ The AllowanceAutopilot reactive contract allowed to trigger payouts.
    constructor(IPayable callbackProxy_, address autopilot_) AbstractCallback(callbackProxy_, autopilot_) {
        owner = msg.sender;
    }

    receive() external payable override {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Create or replace the allowance plan. Emits the event the autopilot mirrors.
    function setPlan(address recipient_, uint256 amount_, uint256 intervalSeconds_, uint256 startAt_) external onlyOwner {
        require(recipient_ != address(0), "AllowanceVault: zero recipient");
        require(amount_ > 0, "AllowanceVault: zero amount");
        require(intervalSeconds_ > 0, "AllowanceVault: zero interval");
        recipient = recipient_;
        amount = amount_;
        intervalSeconds = intervalSeconds_;
        startAt = startAt_;
        planActive = true;
        emit PlanSet(recipient_, amount_, intervalSeconds_, startAt_);
    }

    /// @notice Stop future payouts. The autopilot mirrors the cancellation.
    function cancelPlan() external onlyOwner {
        planActive = false;
        emit PlanCancelled(recipient);
    }

    /// @notice Take funds back. The owner's escape hatch; always available.
    function withdraw(uint256 amount_) external onlyOwner {
        (bool ok, ) = owner.call{ value: amount_ }("");
        require(ok, "AllowanceVault: withdraw failed");
        emit Withdrawn(owner, amount_);
    }

    /// @notice Execute one scheduled payout. Callable only by the Reactive
    ///         callback proxy on behalf of the AllowanceAutopilot contract:
    ///         the network injects the reactive contract's address as the
    ///         first argument, and the proxy's identity is enforced by
    ///         `onlyServiceProvider` (inherited from AbstractPayer).
    function pay(address callbackSender_) external onlyCallbackSender(callbackSender_) onlyServiceProvider {
        require(planActive, "AllowanceVault: no active plan");
        payoutCount += 1;
        (bool ok, ) = recipient.call{ value: amount }("");
        require(ok, "AllowanceVault: payout failed");
        emit Paid(recipient, amount, block.timestamp);
    }
}
