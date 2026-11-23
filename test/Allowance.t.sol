// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Test} from "forge-std/Test.sol";
import {AllowanceVault} from "../src/AllowanceVault.sol";
import {AllowanceAutopilot} from "../src/AllowanceAutopilot.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";

contract AllowanceTest is Test {
    AllowanceVault v;
    address proxy = address(100);
    address pilot = address(101);
    address recipient = address(102);

    function setUp() public {
        vm.warp(1000);
        v = new AllowanceVault(IPayable(payable(proxy)), pilot);
        vm.deal(address(v), 10 ether);
        v.setPlan(recipient, 1 ether, 100, 1000);
    }

    function payout(uint256 id, uint256 due) internal {
        vm.prank(proxy);
        v.pay(pilot, id, due);
    }

    function testPaysDueSlot() public {
        payout(1, 1000);
        assertEq(recipient.balance, 1 ether);
        assertEq(v.nextDue(), 1100);
    }

    function testRejectsReplay() public {
        payout(1, 1000);
        vm.expectRevert();
        payout(1, 1000);
    }

    function testRejectsEarly() public {
        vm.expectRevert();
        payout(1, 1100);
    }

    function testRejectsWrongSlot() public {
        vm.warp(1200);
        vm.expectRevert();
        payout(1, 1050);
    }

    function testRejectsDirectCaller() public {
        vm.expectRevert();
        v.pay(pilot, 1, 1000);
    }

    function testRejectsForgedPilot() public {
        vm.prank(proxy);
        vm.expectRevert();
        v.pay(address(1), 1, 1000);
    }

    function testCancelStopsQueuedCallback() public {
        v.cancelPlan();
        vm.expectRevert();
        payout(1, 1000);
    }

    function testReplacementRejectsOldCallback() public {
        v.setPlan(recipient, 2 ether, 100, 1000);
        vm.expectRevert();
        payout(1, 1000);
        payout(2, 1000);
        assertEq(recipient.balance, 2 ether);
    }

    function testLaterSlotCanProceedAfterMiss() public {
        vm.warp(1200);
        payout(1, 1200);
        assertEq(recipient.balance, 1 ether);
        vm.expectRevert();
        payout(1, 1100);
    }

    function testTransferFailureDoesNotConsumeSlot() public {
        vm.deal(address(v), 0);
        vm.expectRevert();
        payout(1, 1000);
        assertEq(v.nextDue(), 1000);
        assertEq(v.payoutCount(), 0);
    }

    function testOnlyOwnerCanEditOrWithdraw() public {
        vm.prank(recipient);
        vm.expectRevert();
        v.setPlan(recipient, 1, 1, 1);
        vm.prank(recipient);
        vm.expectRevert();
        v.withdraw(1);
    }

    function testOwnerWithdrawal() public {
        uint256 beforeBalance = address(this).balance;
        v.withdraw(2 ether);
        assertEq(address(this).balance, beforeBalance + 2 ether);
    }

    function testFuzzReplay(uint64 interval) public {
        vm.assume(interval > 0);
        v.setPlan(recipient, 1, uint256(interval), 1000);
        payout(2, 1000);
        vm.warp(1000 + uint256(interval));
        payout(2, 1000 + uint256(interval));
        vm.expectRevert();
        payout(2, 1000);
    }
    receive() external payable {}
}

contract AutopilotTest is Test {
    address system = 0x8888888888888888888888888888888888888888;
    address vault = address(201);
    AllowanceAutopilot a;

    function setUp() public {
        vm.mockCall(system, bytes(""), bytes(""));
        a = new AllowanceAutopilot(84532, vault);
        vm.warp(1000);
    }

    function plan(uint256 chain, address source, uint256 id) internal pure returns (IReactive.LogRecord memory l) {
        l.chainId = chain;
        l.contractAddress = source;
        l.topic0 = uint256(keccak256("PlanSet(uint256,address,uint256,uint256,uint256)"));
        l.topic1 = id;
        l.topic2 = uint160(address(202));
        l.data = abi.encode(uint256(1), uint256(100), uint256(1000));
    }

    function deliver(IReactive.LogRecord memory l) internal {
        vm.prank(system);
        a.react(l);
    }

    function testMirrorsValidOrigin() public {
        deliver(plan(84532, vault, 1));
        assertTrue(a.active());
        assertEq(a.planId(), 1);
    }

    function testRejectsWrongOriginChain() public {
        deliver(plan(1, vault, 1));
        assertFalse(a.active());
    }

    function testRejectsWrongVault() public {
        deliver(plan(84532, address(203), 1));
        assertFalse(a.active());
    }

    function testStalePlanCannotOverwrite() public {
        deliver(plan(84532, vault, 2));
        deliver(plan(84532, vault, 1));
        assertEq(a.planId(), 2);
    }

    function testOnlySystem() public {
        vm.expectRevert();
        a.react(plan(84532, vault, 1));
    }

    function cron(uint256 chain, address source) internal pure returns (IReactive.LogRecord memory l) {
        l.chainId = chain;
        l.contractAddress = source;
        l.topic0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    }

    function testCronDispatchesAndAdvances() public {
        deliver(plan(84532, vault, 1));
        deliver(cron(block.chainid, 0x0000000000000000000000000000000000fffFfF));
        assertEq(a.payoutsFired(), 1);
        assertEq(a.nextDue(), 1100);
        deliver(cron(block.chainid, 0x0000000000000000000000000000000000fffFfF));
        assertEq(a.payoutsFired(), 1);
    }

    function testForgedCronIgnored() public {
        deliver(plan(84532, vault, 1));
        deliver(cron(block.chainid, address(999)));
        assertEq(a.payoutsFired(), 0);
    }

    function testPausedCronIgnored() public {
        deliver(plan(84532, vault, 1));
        a.pause();
        deliver(cron(block.chainid, 0x0000000000000000000000000000000000fffFfF));
        assertEq(a.payoutsFired(), 0);
    }

    function testPauseIsIdempotenceGuarded() public {
        a.pause();
        assertTrue(a.paused());
        vm.expectRevert();
        a.pause();
        a.resume();
        assertFalse(a.paused());
    }
}
