// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Waffle} from "../src/Waffle.sol";

contract WaffleTest is Test {
    Waffle public waffle;
    
    address public seller;
    address public buyer1;
    address public buyer2;
    address public buyer3;
    address public outsider;
    
    uint256 constant ENTRY_PRICE = 0.001 ether;
    uint256 constant TARGET_ENTRIES = 3;
    uint256 constant DURATION = 7 days;
    uint256 constant SELLER_DEPOSIT = 0.01 ether;
    
    bytes32 constant SELLER_SECRET = keccak256("my_super_secret_key_123");
    bytes32 public SELLER_SECRET_HASH;

    function setUp() public {
        waffle = new Waffle();
        
        seller = makeAddr("seller");
        buyer1 = makeAddr("buyer1");
        buyer2 = makeAddr("buyer2");
        buyer3 = makeAddr("buyer3");
        outsider = makeAddr("outsider");
        
        vm.deal(seller, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(buyer3, 100 ether);
        vm.deal(outsider, 100 ether);
        
        SELLER_SECRET_HASH = keccak256(abi.encodePacked(SELLER_SECRET));
    }

    function test_CreateLottery_Success() public {
        console.log("=== createLottery Test ===");
        
        vm.prank(seller);
        uint256 id = waffle.createLottery{value: SELLER_DEPOSIT}(
            ENTRY_PRICE,
            TARGET_ENTRIES,
            DURATION,
            SELLER_SECRET_HASH
        );
        
        assertEq(id, 0);
        assertEq(waffle.lotteryCount(), 1);
        
        Waffle.Lottery memory lottery = waffle.getLottery(0);
        assertEq(lottery.seller, seller);
        assertEq(lottery.entryPrice, ENTRY_PRICE);
        assertEq(lottery.targetEntries, TARGET_ENTRIES);
        assertEq(lottery.totalEntries, 0);
        assertEq(lottery.depositAmount, SELLER_DEPOSIT);
        assertEq(lottery.secretHash, SELLER_SECRET_HASH);
        assertEq(uint256(lottery.status), uint256(Waffle.LotteryStatus.OPEN));
        
        console.log("Lottery created with ID:", id);
        console.log("Seller:", lottery.seller);
        console.log("Entry price:", lottery.entryPrice);
        console.log("Contract balance:", waffle.getContractBalance());
    }

    function test_CreateLottery_RevertInsufficientDeposit() public {
        console.log("=== Insufficient Deposit Test ===");
        
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                Waffle.InsufficientDeposit.selector,
                0.005 ether,
                0.01 ether
            )
        );
        waffle.createLottery{value: 0.005 ether}(
            ENTRY_PRICE,
            TARGET_ENTRIES,
            DURATION,
            SELLER_SECRET_HASH
        );
        
        console.log("Correctly reverted for insufficient deposit");
    }

    function test_EnterLottery_Success() public {
        console.log("=== enterLottery Test ===");
        
        _createLottery();
        
        bytes32 nullifier1 = _generateNullifier(buyer1, 0);
        
        vm.prank(buyer1);
        waffle.enterLottery{value: ENTRY_PRICE}(0, nullifier1);
        
        assertEq(waffle.getParticipantCount(0), 1);
        
        Waffle.Participant memory p = waffle.getParticipant(0, 0);
        assertEq(p.walletAddress, buyer1);
        assertEq(p.nullifierHash, nullifier1);
        
        assertTrue(waffle.isNullifierUsed(0, nullifier1));
        
        console.log("Participant entered successfully");
        console.log("Participant address:", p.walletAddress);
        console.log("Total participants:", waffle.getParticipantCount(0));
    }

    function test_EnterLottery_RevertDuplicateNullifier() public {
        console.log("=== Duplicate Nullifier Test ===");
        
        _createLottery();
        
        bytes32 nullifier = _generateNullifier(buyer1, 0);
        
        vm.prank(buyer1);
        waffle.enterLottery{value: ENTRY_PRICE}(0, nullifier);
        
        vm.prank(buyer2);
        vm.expectRevert(
            abi.encodeWithSelector(Waffle.AlreadyParticipated.selector, nullifier)
        );
        waffle.enterLottery{value: ENTRY_PRICE}(0, nullifier);
        
        console.log("Correctly prevented duplicate nullifier");
    }

    function test_EnterLottery_RevertSellerParticipation() public {
        console.log("=== Seller Cannot Participate Test ===");
        
        _createLottery();
        
        bytes32 nullifier = _generateNullifier(seller, 0);
        
        vm.prank(seller);
        vm.expectRevert(Waffle.SellerCannotParticipate.selector);
        waffle.enterLottery{value: ENTRY_PRICE}(0, nullifier);
        
        console.log("Correctly prevented seller from participating");
    }

    function test_EnterLottery_AutoCloseOnTarget() public {
        console.log("=== Auto Close Test ===");
        
        _createLottery();
        
        _enterLottery(buyer1, 0);
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.OPEN));
        
        _enterLottery(buyer2, 0);
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.OPEN));
        
        _enterLottery(buyer3, 0);
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.CLOSED));
        
        console.log("Lottery auto-closed after reaching target");
    }

    function test_PickWinner_Success() public {
        console.log("=== pickWinner Test ===");
        
        _createAndFillLottery();
        
        Waffle.Lottery memory beforeLottery = waffle.getLottery(0);
        assertEq(beforeLottery.winner, address(0));
        
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        
        Waffle.Lottery memory afterLottery = waffle.getLottery(0);
        
        assertTrue(afterLottery.winner != address(0));
        assertTrue(afterLottery.randomSeed != bytes32(0));
        assertEq(uint256(afterLottery.status), uint256(Waffle.LotteryStatus.WAITING_DELIVERY));
        
        bool isValidWinner = (afterLottery.winner == buyer1 || afterLottery.winner == buyer2 || afterLottery.winner == buyer3);
        assertTrue(isValidWinner);
        
        console.log("Winner selected:", afterLottery.winner);
    }

    function test_PickWinner_RevertInvalidSecret() public {
        console.log("=== Invalid Secret Test ===");
        
        _createAndFillLottery();
        
        bytes32 wrongSecret = keccak256("wrong_secret");
        bytes32 wrongHash = keccak256(abi.encodePacked(wrongSecret));
        
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                Waffle.InvalidSecretKey.selector,
                wrongHash,
                SELLER_SECRET_HASH
            )
        );
        waffle.pickWinner(0, wrongSecret);
        
        console.log("Correctly rejected wrong secret key");
    }

    function test_PickWinner_AfterDeadline() public {
        console.log("=== Pick Winner After Deadline Test ===");
        
        _createLottery();
        _enterLottery(buyer1, 0);
        _enterLottery(buyer2, 0);
        
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.OPEN));
        
        vm.warp(block.timestamp + DURATION + 1);
        
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.WAITING_DELIVERY));
        
        console.log("Winner picked after deadline with fewer participants");
    }

    function test_HappyPath_FullFlow() public {
        console.log("");
        console.log("========================================");
        console.log("       HAPPY PATH - FULL FLOW TEST");
        console.log("========================================");
        console.log("");
        
        console.log("Step 1: Seller creates lottery");
        console.log("  Deposit:", SELLER_DEPOSIT);
        console.log("  Entry price:", ENTRY_PRICE);
        console.log("  Target entries:", TARGET_ENTRIES);
        
        vm.prank(seller);
        waffle.createLottery{value: SELLER_DEPOSIT}(
            ENTRY_PRICE,
            TARGET_ENTRIES,
            DURATION,
            SELLER_SECRET_HASH
        );
        
        console.log("  [OK] Lottery created");
        console.log("");
        
        console.log("Step 2: Buyers enter lottery");
        _enterLottery(buyer1, 0);
        console.log("  Buyer1 entered");
        _enterLottery(buyer2, 0);
        console.log("  Buyer2 entered");
        _enterLottery(buyer3, 0);
        console.log("  Buyer3 entered");
        console.log("  [OK] All buyers entered, lottery auto-closed");
        console.log("");
        
        console.log("Step 3: Seller picks winner");
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        
        Waffle.Lottery memory lottery = waffle.getLottery(0);
        console.log("  [OK] Winner:", lottery.winner);
        console.log("");
        
        console.log("Step 4: Seller ships item");
        vm.prank(seller);
        waffle.markShipped(0);
        console.log("  [OK] Item marked as shipped");
        console.log("");
        
        console.log("Step 5: Winner confirms receipt");
        uint256 sellerBalanceBefore = seller.balance;
        uint256 expectedPayout = SELLER_DEPOSIT + (ENTRY_PRICE * TARGET_ENTRIES);
        
        vm.prank(lottery.winner);
        waffle.confirmReceived(0);
        
        uint256 sellerBalanceAfter = seller.balance;
        uint256 actualPayout = sellerBalanceAfter - sellerBalanceBefore;
        
        assertEq(actualPayout, expectedPayout);
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.COMPLETED));
        
        console.log("  [OK] Receipt confirmed");
        console.log("  Seller received:", actualPayout);
        console.log("");
        
        console.log("========================================");
        console.log("       HAPPY PATH COMPLETED!");
        console.log("========================================");
    }

    function test_MAD_DisputeFlow() public {
        console.log("");
        console.log("========================================");
        console.log("    MAD PATH - DISPUTE FLOW TEST");
        console.log("    (Mutually Assured Destruction)");
        console.log("========================================");
        console.log("");
        
        console.log("Scenario: Winner receives item but refuses to confirm");
        console.log("");
        
        console.log("Step 1-4: Same as happy path until shipping");
        _createAndFillLottery();
        
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        
        Waffle.Lottery memory lottery = waffle.getLottery(0);
        console.log("  Winner:", lottery.winner);
        
        vm.prank(seller);
        waffle.markShipped(0);
        console.log("  Item shipped");
        console.log("");
        
        console.log("Step 5: Winner does NOT confirm (7 days pass)");
        console.log("  Simulating 8 days passing...");
        vm.warp(block.timestamp + 8 days);
        console.log("");
        
        console.log("Step 6: Seller claims dispute");
        uint256 contractBalanceBefore = waffle.getContractBalance();
        uint256 burnAddressBalanceBefore = waffle.BURN_ADDRESS().balance;
        
        console.log("  Contract balance before:", contractBalanceBefore);
        console.log("  Burn address balance before:", burnAddressBalanceBefore);
        
        vm.prank(seller);
        waffle.claimDispute(0);
        
        uint256 contractBalanceAfter = waffle.getContractBalance();
        uint256 burnAddressBalanceAfter = waffle.BURN_ADDRESS().balance;
        uint256 burnedAmount = burnAddressBalanceAfter - burnAddressBalanceBefore;
        
        assertEq(contractBalanceAfter, 0);
        assertEq(uint256(waffle.getLotteryStatus(0)), uint256(Waffle.LotteryStatus.DISPUTED));
        
        console.log("");
        console.log("  [BURNED] Contract balance after:", contractBalanceAfter);
        console.log("  [BURNED] Amount burned:", burnedAmount);
        console.log("");
        
        console.log("========================================");
        console.log("    MAD EXECUTED - NOBODY WINS!");
        console.log("========================================");
    }

    function test_MAD_RevertTooEarly() public {
        console.log("=== Dispute Too Early Test ===");
        
        _createAndFillLottery();
        
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        
        vm.prank(seller);
        waffle.markShipped(0);
        
        vm.warp(block.timestamp + 3 days);
        
        uint256 canDisputeAfter = waffle.getDisputeTime(0);
        
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                Waffle.DisputePeriodNotOver.selector,
                canDisputeAfter,
                block.timestamp
            )
        );
        waffle.claimDispute(0);
        
        console.log("Correctly prevented early dispute");
        console.log("Can dispute after:", canDisputeAfter);
        console.log("Current time:", block.timestamp);
    }

    function test_Refund_AfterDeadline() public {
        console.log("=== Refund Test ===");
        
        _createLottery();
        _enterLottery(buyer1, 0);
        _enterLottery(buyer2, 0);
        
        uint256 buyer1BalanceBefore = buyer1.balance;
        uint256 buyer2BalanceBefore = buyer2.balance;
        uint256 sellerBalanceBefore = seller.balance;
        
        vm.warp(block.timestamp + DURATION + 1);
        
        vm.prank(seller);
        waffle.refundAll(0);
        
        assertEq(buyer1.balance, buyer1BalanceBefore + ENTRY_PRICE);
        assertEq(buyer2.balance, buyer2BalanceBefore + ENTRY_PRICE);
        assertEq(seller.balance, sellerBalanceBefore + SELLER_DEPOSIT);
        
        console.log("All participants refunded successfully");
    }

    function test_StatusTransitions() public {
        console.log("=== Status Transition Test ===");
        
        _createLottery();
        assertEq(uint256(waffle.getLotteryStatus(0)), 0);
        console.log("OPEN (0)");
        
        _enterLottery(buyer1, 0);
        _enterLottery(buyer2, 0);
        _enterLottery(buyer3, 0);
        assertEq(uint256(waffle.getLotteryStatus(0)), 1);
        console.log("-> CLOSED (1)");
        
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        assertEq(uint256(waffle.getLotteryStatus(0)), 3);
        console.log("-> WAITING_DELIVERY (3)");
        
        vm.prank(seller);
        waffle.markShipped(0);
        assertEq(uint256(waffle.getLotteryStatus(0)), 4);
        console.log("-> SHIPPED (4)");
        
        Waffle.Lottery memory lottery = waffle.getLottery(0);
        vm.prank(lottery.winner);
        waffle.confirmReceived(0);
        assertEq(uint256(waffle.getLotteryStatus(0)), 5);
        console.log("-> COMPLETED (5)");
        
        console.log("");
        console.log("All status transitions verified!");
    }

    function test_GasOptimization() public {
        console.log("=== Gas Usage Report ===");
        
        uint256 gasBefore;
        uint256 gasAfter;
        
        gasBefore = gasleft();
        vm.prank(seller);
        waffle.createLottery{value: SELLER_DEPOSIT}(
            ENTRY_PRICE,
            TARGET_ENTRIES,
            DURATION,
            SELLER_SECRET_HASH
        );
        gasAfter = gasleft();
        console.log("createLottery gas:", gasBefore - gasAfter);
        
        gasBefore = gasleft();
        _enterLottery(buyer1, 0);
        gasAfter = gasleft();
        console.log("enterLottery gas:", gasBefore - gasAfter);
        
        _enterLottery(buyer2, 0);
        _enterLottery(buyer3, 0);
        
        gasBefore = gasleft();
        vm.prank(seller);
        waffle.pickWinner(0, SELLER_SECRET);
        gasAfter = gasleft();
        console.log("pickWinner gas:", gasBefore - gasAfter);
        
        gasBefore = gasleft();
        vm.prank(seller);
        waffle.markShipped(0);
        gasAfter = gasleft();
        console.log("markShipped gas:", gasBefore - gasAfter);
        
        Waffle.Lottery memory lottery = waffle.getLottery(0);
        gasBefore = gasleft();
        vm.prank(lottery.winner);
        waffle.confirmReceived(0);
        gasAfter = gasleft();
        console.log("confirmReceived gas:", gasBefore - gasAfter);
    }

    function _createLottery() internal returns (uint256) {
        vm.prank(seller);
        return waffle.createLottery{value: SELLER_DEPOSIT}(
            ENTRY_PRICE,
            TARGET_ENTRIES,
            DURATION,
            SELLER_SECRET_HASH
        );
    }

    function _enterLottery(address buyer, uint256 lotteryId) internal {
        bytes32 nullifier = _generateNullifier(buyer, lotteryId);
        vm.prank(buyer);
        waffle.enterLottery{value: ENTRY_PRICE}(lotteryId, nullifier);
    }

    function _createAndFillLottery() internal returns (uint256) {
        uint256 id = _createLottery();
        _enterLottery(buyer1, id);
        _enterLottery(buyer2, id);
        _enterLottery(buyer3, id);
        return id;
    }

    function _generateNullifier(address user, uint256 lotteryId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("worldid", user, lotteryId));
    }
}