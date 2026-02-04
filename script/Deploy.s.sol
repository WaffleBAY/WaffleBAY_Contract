// script/DeployFactory.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/WaffleFactory.sol";

contract DeployFactoryScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address worldIdAddress = vm.envAddress("WORLD_ID_ADDRESS");
        address worldFoundation = vm.envAddress("WORLD_FOUNDATION_ADDRESS");
        address opsWallet = vm.envAddress("OPS_WALLET_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        string memory appId = vm.envString("APP_ID");

        vm.startBroadcast(deployerPrivateKey);

        WaffleFactory factory = new WaffleFactory(
            worldIdAddress,
            appId,
            worldFoundation,
            opsWallet,
            operator
        );

        console.log("WaffleFactory deployed to:", address(factory));

        vm.stopBroadcast();
    }
}