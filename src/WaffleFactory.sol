// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { WaffleMarket } from "./WaffleMarket.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { IWorldID } from "./interfaces/IWorldID.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleFactory is Ownable {
    
    // 글로벌 설정
    address public immutable worldId;
    string public appId;
    address public worldFoundation;  // 수수료 수령 주소 (3%)
    address public immutable treasury; // ✅ 수수료 수령 주소 (2%) - 금고
    address public operator;
    
    // 생성된 마켓 목록
    address[] public markets;
    mapping(address => bool) public isMarket;
    
    uint256 public marketCount;
    
    // 이벤트
    event MarketCreated(
        uint256 indexed marketId,
        address indexed marketAddress,
        address indexed seller,
        WaffleLib.MarketType mType
    );
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event FeeRecipientsUpdated(address worldFoundation, address opsWallet);

    constructor(
        address _worldId,
        string memory _appId,
        address _worldFoundation,
        address _treasury, // ✅ 생성자에서 금고 주소를 받습니다.
        address _operator
    ) Ownable(msg.sender) {
        worldId = _worldId;
        appId = _appId;
        worldFoundation = _worldFoundation;
        treasury = _treasury; // 저장
        operator = _operator;
    }
    
    // 마켓 생성 함수
    // 판매자는 World ID 인증 후 sellerNullifierHash를 전달
    function createMarket(
        uint256 _root,
        uint256 _sellerNullifierHash,
        uint256[8] calldata _sellerProof,
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration
    ) external payable returns (address) {

        // 판매자 World ID 검증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _sellerNullifierHash,
        //     ByteHasher.hashToField(abi.encodePacked(appId)),
        //     _sellerProof
        // );

        // 두 타입 모두 판매자 보증금 필요 (goalAmount × 15%)
        uint256 requiredDeposit = (_goalAmount * 15) / 100;
        require(msg.value >= requiredDeposit, "Insufficient seller deposit");

        WaffleMarket newMarket = new WaffleMarket{value: msg.value}(
            msg.sender,              // _seller
            worldId,                 // _worldId
            appId,                   // _appId
            worldFoundation,         // _worldFoundation
            treasury,                // _opsWallet (금고 주소)
            operator,                // _operator
            _mType,                  // _mType
            _ticketPrice,            // _ticketPrice
            _goalAmount,             // _goalAmount
            _preparedQuantity,       // _preparedQuantity
            _duration,               // _duration
            _sellerNullifierHash     // 🔐 sellerNullifierHash → Market 내부에서 commitment 자동 생성
        );
        
        // 마켓 등록
        address marketAddress = address(newMarket);
        markets.push(marketAddress);
        isMarket[marketAddress] = true;
        
        uint256 currentMarketId = marketCount;
        marketCount++;
        
        emit MarketCreated(
            currentMarketId,
            marketAddress,
            msg.sender,
            _mType
        );

        return marketAddress;
    }
    
    // 조회 함수들
    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }
    
    function getMarket(uint256 _index) external view returns (address) {
        require(_index < markets.length, "Invalid index");
        return markets[_index];
    }
    
    function getAllMarkets() external view returns (address[] memory) {
        return markets;
    }
    
    // 설정 변경 (owner만)
    function updateOperator(address _newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = _newOperator;
        emit OperatorUpdated(oldOperator, _newOperator);
    }
    
    function updateFeeRecipients(
        address _worldFoundation
    ) external onlyOwner {
        // treasury는 immutable이라 변경 불가, 재단 주소만 변경 가능
        worldFoundation = _worldFoundation;
        emit FeeRecipientsUpdated(_worldFoundation, treasury);
    }
}