// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { WaffleMarket } from "../src/WaffleMarket.sol";

contract DeployWaffle is Script {
    function run() external {
        // .env 파일에서 정보 가져오기
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("APP_ID");
        
        // World Chain Sepolia 설정값
        address worldIdRouter = 0x11cA3127182f7583EfC416a8771BD4d11Fae433D; 
        address foundationWallet = vm.addr(deployerPrivateKey); // 테스트용으로 배포자를 수수료 수취인으로
        address opsWallet = vm.addr(deployerPrivateKey);        // 테스트용

        // 배포 시작 (여기서부터 가스비가 나갑니다)
        vm.startBroadcast(deployerPrivateKey);

        WaffleMarket market = new WaffleMarket(
            worldIdRouter,
            appId,
            foundationWallet,
            opsWallet
        );

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("Deployed WaffleMarket at:", address(market));
        console.log("==========================================");
    }
}