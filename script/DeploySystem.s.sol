// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { WaffleTreasury } from "../src/WaffleTreasury.sol";
import { WaffleFactory } from "../src/WaffleFactory.sol";

contract DeploySystem is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("APP_ID");

        // World Chain Sepolia 설정
        address worldIdRouter = vm.parseAddress("0x57f928158C3EE7CDad1e4D8642503c4D0201f611");
        
        // 지갑 주소 설정
        address deployer = vm.addr(deployerPrivateKey);
        address foundationWallet = address(0x57F928155A6E469B5664426a99a2D0D8f1fdF611);
        address operator = deployer; 

        
        address[] memory teamMembers = new address[](4);
        teamMembers[0] = deployer; 
        teamMembers[1] = 0xc0Ee55c4d1f05730FFAe7ad09AF5f8c7d5bcD7FC; // 박훈일
        teamMembers[2] = 0xc3555D7DB235D326ced112Db50290bE881FFa4BF; // 오창현
        teamMembers[3] = 0x4986B11281DE2d9Fe721dB0d1250d0e4897a84B1; // 권상현

        vm.startBroadcast(deployerPrivateKey);

        // 1. 금고(Treasury) 배포
        WaffleTreasury treasury = new WaffleTreasury(teamMembers);
        console.log("Treasury Deployed at:", address(treasury));

        // 2. 공장(Factory) 배포
        // 파라미터 5개 확인: (WorldID, AppID, 재단, 금고, 운영자)
        WaffleFactory factory = new WaffleFactory(
            worldIdRouter,
            appId,
            foundationWallet,
            address(treasury), // 4번째: 금고
            operator           // 
        );
        console.log("Factory Deployed at:", address(factory));

        vm.stopBroadcast();
    }
}