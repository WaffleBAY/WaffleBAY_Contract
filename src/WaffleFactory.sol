// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { WaffleMarket } from "./WaffleMarket.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";

contract WaffleFactory is Ownable {
    
    // 글로벌 설정
    address public immutable worldId;
    string public appId;
    address public worldFoundation;  // 수수료 수령 주소 (3%)
    address public opsWallet;        // 운영 수수료 (2%)
    address public operator;         // commitSecret, revealSecret 호출 권한
    
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
        address _opsWallet,
        address _operator
    ) Ownable(msg.sender) {
        worldId = _worldId;
        appId = _appId;
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
        operator = _operator;
    }
    
    // 마켓 생성 함수
    function createMarket(
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration
    ) external payable returns (address) {
        
        // Raffle일 경우 보증금 검증
        if (_mType == WaffleLib.MarketType.RAFFLE) {
            uint256 requiredDeposit = (_goalAmount * 15) / 100;
            require(msg.value >= requiredDeposit, "Insufficient seller deposit");
        } else {
            require(msg.value == 0, "Lottery does not require deposit");
        }
        
        // 🆕 새 Market 컨트랙트 배포
        WaffleMarket newMarket = new WaffleMarket{value: msg.value}(
            msg.sender,           // seller
            worldId,
            appId,
            worldFoundation,
            opsWallet,
            operator,             // operator 전달
            _mType,
            _ticketPrice,
            _goalAmount,
            _preparedQuantity,
            _duration
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
        address _worldFoundation,
        address _opsWallet
    ) external onlyOwner {
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
        emit FeeRecipientsUpdated(_worldFoundation, _opsWallet);
    }
}