// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
// 정확한 상대 경로와 명시적 Import 사용
import { WaffleMarket } from "../src/WaffleMarket.sol";
import { IWorldID } from "../src/interfaces/IWorldID.sol";
import { WaffleLib } from "../src/libraries/WaffleLib.sol";

contract MockWorldID is IWorldID {
    function verifyProof(uint256, uint256, uint256, uint256, uint256, uint256[8] calldata) external view override {}
}

contract WaffleMarketTest is Test {
    WaffleMarket market;
    MockWorldID mockWorldId;
    
    address seller = makeAddr("seller");
    address user1 = makeAddr("user1");
    address foundation = makeAddr("foundation");
    address ops = makeAddr("ops");

    function setUp() public {
        mockWorldId = new MockWorldID();
        market = new WaffleMarket(address(mockWorldId), "app_test", foundation, ops);
        vm.deal(seller, 10 ether);
        vm.deal(user1, 10 ether);
    }

    function testRaffleFlow() public {
        vm.startPrank(seller);
        uint256 goal = 1 ether;
        uint256 ticket = 0.1 ether;
        market.createMarket{value: 0.15 ether}(
            WaffleLib.MarketType.RAFFLE, ticket, goal, 1, 1 days
        );
        market.openMarket(1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 pay = ticket + 0.005 ether;
        uint256 preFoundation = foundation.balance;
        market.enter{value: pay}(1, 0, 111, [uint256(0),0,0,0,0,0,0,0]);
        
        assertEq(foundation.balance - preFoundation, ticket * 3 / 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        market.closeEntries(1);
        
        vm.prank(user1);
        market.confirmReceipt(1);
    }
}