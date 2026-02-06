// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { WaffleFactory } from "../src/WaffleFactory.sol";
import { WaffleMarket } from "../src/WaffleMarket.sol";
import { IWorldID } from "../src/interfaces/IWorldID.sol";
import { WaffleLib } from "../src/libraries/WaffleLib.sol";

contract MockWorldID is IWorldID {
    function verifyProof(uint256, uint256, uint256, uint256, uint256, uint256[8] calldata) external view override {}
}

contract WaffleMarketTest is Test {
    WaffleFactory factory;
    WaffleMarket market;
    MockWorldID mockWorldId;

    address seller = makeAddr("seller");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address foundation = makeAddr("foundation");
    address ops = makeAddr("ops");
    address operator = makeAddr("operator");

    // 테스트용 seller nullifierHash (World ID 인증 결과)
    uint256 constant SELLER_NULLIFIER = 99999;
    uint256[8] EMPTY_PROOF = [uint256(0),0,0,0,0,0,0,0];

    function setUp() public {
        mockWorldId = new MockWorldID();

        factory = new WaffleFactory(
            address(mockWorldId),
            "app_test",
            foundation,
            ops,
            operator
        );

        vm.deal(seller, 10 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // ━━━━━━━━━━━━━━━ RAFFLE: 전원 당첨 플로우 ━━━━━━━━━━━━━━━
    function testRaffleAllWinFlow() public {
        vm.startPrank(seller);

        uint256 goal = 1 ether;
        uint256 ticket = 0.1 ether;
        uint256 quantity = 2; // 경품 2개, 참여자 ≤ 2이면 전원 당첨
        uint256 duration = 1 days;

        // Factory를 통해 Market 생성 (sellerNullifierHash + World ID proof)
        address marketAddr = factory.createMarket{value: 0.15 ether}(
            1,                            // _root
            SELLER_NULLIFIER,             // _sellerNullifierHash
            EMPTY_PROOF,                  // _sellerProof
            WaffleLib.MarketType.RAFFLE,
            ticket,
            goal,
            quantity,
            duration
        );

        market = WaffleMarket(marketAddr);

        // commitment = hash(sellerNullifierHash + CA) 자동 생성 검증
        bytes32 expectedCommitment = keccak256(abi.encodePacked(SELLER_NULLIFIER, marketAddr));
        assertEq(market.commitment(), expectedCommitment);
        assertEq(market.sellerNullifierHash(), SELLER_NULLIFIER);

        // 마켓 오픈
        market.openMarket();
        vm.stopPrank();

        // 유저 참여
        vm.prank(user1);
        market.enter{value: ticket + 0.005 ether}(1, 111, EMPTY_PROOF);

        // 수수료 검증 (3% → 재단)
        assertEq(foundation.balance, ticket * 3 / 100);

        // 마감 (참여자 1명 ≤ quantity 2 → 전원 당첨, REVEALED 직행)
        vm.warp(block.timestamp + 2 days);
        market.closeEntries();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.REVEALED));

        // 정산
        market.settle();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));

        // 당첨자 보증금 반환
        vm.prank(user1);
        market.claimRefund();
    }

    // ━━━━━━━━━━━━━━━ RAFFLE: 추첨 플로우 (reveal + pick) ━━━━━━━━━━━━━━━
    function testRaffleDrawFlow() public {
        vm.startPrank(seller);

        uint256 goal = 1 ether;
        uint256 ticket = 0.1 ether;
        uint256 quantity = 1; // 경품 1개, 참여자 > 1이면 추첨
        uint256 duration = 1 days;

        address marketAddr = factory.createMarket{value: 0.15 ether}(
            1, SELLER_NULLIFIER, EMPTY_PROOF,
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration
        );

        market = WaffleMarket(marketAddr);
        market.openMarket();
        vm.stopPrank();

        // 2명 참여 (quantity=1이므로 추첨 필요)
        vm.prank(user1);
        market.enter{value: ticket + 0.005 ether}(1, 111, EMPTY_PROOF);
        vm.prank(user2);
        market.enter{value: ticket + 0.005 ether}(1, 222, EMPTY_PROOF);

        // 마감 → CLOSED (추첨 필요)
        vm.warp(block.timestamp + 2 days);
        market.closeEntries();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.CLOSED));

        // 100블록 대기 후 reveal
        vm.roll(block.number + 101);
        vm.prank(seller);
        market.revealSecret(1, SELLER_NULLIFIER, EMPTY_PROOF);
        assertTrue(market.secretRevealed());

        // 추첨
        market.pickWinners();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.REVEALED));
        assertEq(market.getWinners().length, 1);

        // 정산 + 환불
        market.settle();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
    }

    // ━━━━━━━━━━━━━━━ Reveal 타임아웃 + 슬래싱 ━━━━━━━━━━━━━━━
    function testRevealTimeoutSlashing() public {
        vm.startPrank(seller);

        address marketAddr = factory.createMarket{value: 0.15 ether}(
            1, SELLER_NULLIFIER, EMPTY_PROOF,
            WaffleLib.MarketType.RAFFLE,
            0.1 ether, 1 ether, 1, 1 days
        );

        market = WaffleMarket(marketAddr);
        market.openMarket();
        vm.stopPrank();

        vm.prank(user1);
        market.enter{value: 0.105 ether}(1, 111, EMPTY_PROOF);
        vm.prank(user2);
        market.enter{value: 0.105 ether}(1, 222, EMPTY_PROOF);

        vm.warp(block.timestamp + 2 days);
        market.closeEntries();

        // 150블록 진행 (snapshotBlock + 50 초과)
        vm.roll(block.number + 251);

        uint256 sellerBalBefore = seller.balance;
        uint256 opsBalBefore = ops.balance;

        market.cancelByTimeout();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.FAILED));
        // 판매자: 50% 반환, 운영: 50% 슬래싱
        assertGt(seller.balance, sellerBalBefore);
        assertGt(ops.balance, opsBalBefore);
    }
}
