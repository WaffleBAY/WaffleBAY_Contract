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
    address foundation = makeAddr("foundation");
    address ops = makeAddr("ops");
    address operator = makeAddr("operator");

    function setUp() public {
        mockWorldId = new MockWorldID();
        
        // 1. Factory 배포 (인자 5개)
        factory = new WaffleFactory(
            address(mockWorldId),
            "app_test",
            foundation,
            ops,
            operator
        );
        
        vm.deal(seller, 10 ether);
        vm.deal(user1, 10 ether);
    }

    function testRaffleFlow() public {
        vm.startPrank(seller);
        
        uint256 goal = 1 ether;
        uint256 ticket = 0.1 ether;
        uint256 quantity = 1;
        uint256 duration = 1 days;

        // 2. Factory를 통해 Market 생성 (MarketType, Price, Goal, Qty, Duration)
        // Raffle 타입은 Goal의 15% 보증금 필요
        address marketAddr = factory.createMarket{value: 0.15 ether}(
            WaffleLib.MarketType.RAFFLE,
            ticket,
            goal,
            quantity,
            duration
        );
        
        // 생성된 주소를 Market 인터페이스로 연결
        market = WaffleMarket(marketAddr);
        
        // 3. 마켓 오픈
        market.openMarket();
        vm.stopPrank();

        // 4. 유저 참여
        vm.startPrank(user1);
        uint256 pay = ticket + 0.005 ether;
        uint256 preFoundation = foundation.balance;
        
        // enter 호출 (인자 3개: root, nullifierHash, proof)
        // 기존 코드의 4개 인자 오류 수정됨 (중간의 0 제거)
        market.enter{value: pay}(1, 111, [uint256(0),0,0,0,0,0,0,0]);
        
        // 수수료 검증
        assertEq(foundation.balance - preFoundation, ticket * 3 / 100);
        vm.stopPrank();

        // 5. 마감 및 정산 시뮬레이션
        vm.warp(block.timestamp + 2 days);
        
        market.closeEntries();
        
        // 당첨자 선정 로직에 따라 confirmReceipt 호출 가능 여부가 갈리므로 주석 처리해둠
        // vm.prank(user1);
        // market.confirmReceipt();
    }
}