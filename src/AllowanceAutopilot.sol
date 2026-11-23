// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @title AllowanceAutopilot — the reactive half of a personal allowance plan.
/// @notice Lives on Reactive Network (Lasna testnet). It mirrors the plan the
///         owner sets on AllowanceVault by listening to that vault's events on
///         the origin chain, then uses the network's own CRON events to fire a
///         callback payout every time the plan comes due. Set it and forget it:
///         no keeper, no bot, no server.
contract AllowanceAutopilot is AbstractReactive {
    /// @dev The legacy system contract emits the network's Cron events.
    address private constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;
    /// @dev Cron100 fires every 100 Reactive blocks (~2 minutes).
    uint256 private constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    address public owner;
    uint256 public originChainId;
    address public vault;

    // The mirrored plan, learned from the vault's PlanSet / PlanCancelled events.
    address public recipient;
    uint256 public amount;
    uint256 public intervalSeconds;
    uint256 public nextDue;
    bool public active;

    uint64 public callbackGasLimit = 200_000;
    uint256 public payoutsFired;

    event PayoutDispatched(uint256 indexed payoutNumber, address indexed recipient, uint256 amount, uint256 dueAt);
    event PlanMirrored(address indexed recipient, uint256 amount, uint256 intervalSeconds, uint256 nextDue);
    event PlanStopped();

    modifier onlyOwner() {
        require(msg.sender == owner, "AllowanceAutopilot: not owner");
        _;
    }

    /// @param originChainId_ Chain the vault lives on (e.g. 84532 Base Sepolia).
    /// @param vault_ Deployed AllowanceVault address. Fund this contract at
    ///        deployment: every CRON tick and every callback is billed to it.
    constructor(uint256 originChainId_, address vault_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        vault = vault_;

        uint256 planSetTopic = uint256(keccak256("PlanSet(address,uint256,uint256,uint256)"));
        uint256 planCancelledTopic = uint256(keccak256("PlanCancelled(address)"));

        SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, vault_, planSetTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, vault_, planCancelledTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        uint256 planSetTopic = uint256(keccak256("PlanSet(address,uint256,uint256,uint256)"));
        uint256 planCancelledTopic = uint256(keccak256("PlanCancelled(address)"));

        if (log_.topic0 == CRON100_TOPIC_0) {
            if (active && block.timestamp >= nextDue) {
                nextDue += intervalSeconds;
                payoutsFired += 1;
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: originChainId,
                        recipient: vault,
                        gasLimit: callbackGasLimit,
                        // The network injects this contract's address as the
                        // first argument for authentication on the vault side.
                        payload: abi.encodeWithSignature("pay(address)", address(0))
                    })
                );
                emit PayoutDispatched(payoutsFired, recipient, amount, nextDue - intervalSeconds);
            }
        } else if (log_.topic0 == planSetTopic && log_.contractAddress == vault) {
            recipient = address(uint160(log_.topic1));
            (amount, intervalSeconds, nextDue) = abi.decode(log_.data, (uint256, uint256, uint256));
            active = true;
            emit PlanMirrored(recipient, amount, intervalSeconds, nextDue);
        } else if (log_.topic0 == planCancelledTopic && log_.contractAddress == vault) {
            active = false;
            emit PlanStopped();
        }
    }

    /// @notice Point at a different vault (e.g. after redeploying it).
    function setVault(uint256 originChainId_, address vault_) external onlyOwner {
        originChainId = originChainId_;
        vault = vault_;
        active = false;
    }

    /// @notice Tune the gas handed to each payout callback.
    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        callbackGasLimit = gasLimit_;
    }

    /// @notice Stop the meter: unsubscribe from CRON so ticks stop billing.
    function pause() external onlyOwner {
        SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Resume CRON billing after a pause.
    function resume() external onlyOwner {
        SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Recover unused funding.
    function withdraw(uint256 amount_) external onlyOwner {
        (bool ok, ) = owner.call{ value: amount_ }("");
        require(ok, "AllowanceAutopilot: withdraw failed");
    }
}
