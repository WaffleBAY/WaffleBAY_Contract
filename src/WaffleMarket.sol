// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWorldID } from "./interfaces/IWorldID.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleMarket is ReentrancyGuard {

    // 이 마켓의 정보 (Factory가 아닌 개별 마켓 데이터)
    address public immutable seller;
    address public immutable factory;
    address public immutable worldId;
    uint256 public immutable externalNullifier;
    
    address public worldFoundation;
    address public opsWallet;
    address public operator;  // commitSecret, revealSecret 호출 권한
    
    // 마켓 타입
    WaffleLib.MarketType public mType;
    
    // 경제 모델
    uint256 public ticketPrice;
    uint256 public constant PARTICIPANT_DEPOSIT = 0.005 ether;
    uint256 public sellerDeposit;
    uint256 public prizePool;
    
    // 조건
    uint256 public goalAmount;
    uint256 public preparedQuantity;
    uint256 public endTime;
    
    // 상태
    WaffleLib.MarketStatus public status;
    address[] public participants;
    address[] public winners;
    
    // 난수 생성
    uint256 public snapshotBlock;
    bytes32 public commitment;
    uint256 public nonce;
    uint256 public constant REVEAL_TIMEOUT = 1 days;
    uint256 public revealDeadline;
    uint256 public nullifierHashSum;
    
    // 참가자 정보
    mapping(address => WaffleLib.ParticipantInfo) public participantInfos;
    mapping(uint256 => bool) public nullifierHashes;
    
    // 이벤트
    event MarketOpen();
    event Entered(address indexed participant);
    event WinnerSelected(address[] winners);
    event MarketCompleted();
    event MarketFailed(string reason);
    
    // Factory가 배포 시 호출하는 생성자
    constructor(
        address _seller,
        address _worldId,
        string memory _appId,
        address _worldFoundation,
        address _opsWallet,
        address _operator,
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration
    ) payable {
        seller = _seller;
        factory = msg.sender;  // Factory 주소
        worldId = _worldId;
        externalNullifier = ByteHasher.hashToField(abi.encodePacked(_appId));
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
        operator = _operator;
        
        mType = _mType;
        ticketPrice = _ticketPrice;
        goalAmount = _goalAmount;
        preparedQuantity = _preparedQuantity;
        sellerDeposit = msg.value;
        if (_mType == WaffleLib.MarketType.RAFFLE) {
            uint256 requiredDeposit = (_goalAmount * 15) / 100;
            if (msg.value < requiredDeposit) {
                revert WaffleLib.InsufficientFunds(); 
            }
        }
        endTime = block.timestamp + _duration;
        status = WaffleLib.MarketStatus.CREATED;
    }
    
    // Modifier: 판매자만
    modifier onlySeller() {
        if (msg.sender != seller) revert WaffleLib.Unauthorized();
        _;
    }
    
    // Modifier: 운영자만
    modifier onlyOperator() {
        if (msg.sender != operator) revert WaffleLib.Unauthorized();
        _;
    }
    
    // Phase 1: 마켓 오픈
    function openMarket() external onlySeller {
        if (status != WaffleLib.MarketStatus.CREATED) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CREATED);
        
        status = WaffleLib.MarketStatus.OPEN;
        emit MarketOpen();
    }
    
    // Phase 2: 응모
    function enter(
        uint256 _root,
        uint256 _nullifierHash,
        uint256[8] calldata _proof
    ) external payable nonReentrant {
        if (status != WaffleLib.MarketStatus.OPEN) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);
        if (block.timestamp >= endTime) 
            revert WaffleLib.TimeExpired();
        
        uint256 requiredAmount = ticketPrice + PARTICIPANT_DEPOSIT;
        if (msg.value != requiredAmount) 
            revert WaffleLib.InsufficientFunds();

        if (nullifierHashes[_nullifierHash]) 
            revert WaffleLib.AlreadyParticipated();
        
        // WorldID 검증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(_root, 1, ByteHasher.hashToField(abi.encodePacked(msg.sender)), _nullifierHash, externalNullifier, _proof);

        nullifierHashes[_nullifierHash] = true;
        participants.push(msg.sender);
        nullifierHashSum ^= _nullifierHash;
        
        participantInfos[msg.sender] = WaffleLib.ParticipantInfo({
            hasEntered: true,
            isWinner: false,
            paidAmount: msg.value,
            depositRefunded: false
        });

        uint256 feeWorld = (ticketPrice * 3) / 100;
        uint256 feeOps = (ticketPrice * 2) / 100;
        uint256 toPool = ticketPrice - feeWorld - feeOps;

        prizePool += toPool;
        
        _safeTransferETH(worldFoundation, feeWorld);
        _safeTransferETH(opsWallet, feeOps);

        emit Entered(msg.sender);
    }
    
    // Phase 3: 응모 마감
    function closeEntries() external nonReentrant {
        if (block.timestamp < endTime) 
            revert WaffleLib.TimeNotReached();
        if (status != WaffleLib.MarketStatus.OPEN) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);

        snapshotBlock = block.number + 100;

        if (mType == WaffleLib.MarketType.LOTTERY) {
            if (prizePool >= goalAmount) {
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                status = WaffleLib.MarketStatus.FAILED;
                emit MarketFailed("Goal not reached");
            }
        } else {
            if (participants.length > preparedQuantity) {
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                status = WaffleLib.MarketStatus.REVEALED;
                winners = participants;
                for(uint i=0; i<participants.length; i++){
                    participantInfos[participants[i]].isWinner = true;
                }
                emit WinnerSelected(winners);
            }
        }
    }
    
    // Phase 4: Commit (운영자만 호출 가능)
    function commitSecret(
        bytes32 _commitment,
        uint256 _nonce
    ) external onlyOperator {
        if (status != WaffleLib.MarketStatus.CLOSED) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);
        
        if (block.number >= snapshotBlock) 
            revert WaffleLib.TimeExpired();
        
        commitment = _commitment;
        nonce = _nonce;
        status = WaffleLib.MarketStatus.COMMITTED;
        revealDeadline = block.timestamp + REVEAL_TIMEOUT;
    }
    
    // Phase 5: Reveal + 추첨 (운영자만 호출 가능)
    function revealAndPickWinner(
        uint256 _secret,
        uint256 _nonce
    ) external nonReentrant onlyOperator {
        if (status != WaffleLib.MarketStatus.COMMITTED) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.COMMITTED);
        
        if (block.number < snapshotBlock) 
            revert WaffleLib.TimeNotReached();
        
        if (block.number > snapshotBlock + 50) 
            revert WaffleLib.TimeExpired();
        
        if (block.timestamp > revealDeadline) 
            revert WaffleLib.TimeExpired();

        bytes32 computedCommitment = keccak256(abi.encodePacked(_secret, _nonce));
        if (computedCommitment != commitment) 
            revert WaffleLib.VerificationFailed();

        uint256 randomness = uint256(keccak256(abi.encodePacked(
            block.prevrandao, 
            _secret,
            _nonce,
            nullifierHashSum
        )));

        uint256 winnerCount = (mType == WaffleLib.MarketType.LOTTERY) ? 1 : preparedQuantity;
        if (winnerCount > participants.length) winnerCount = participants.length;

        address[] memory tempPool = participants;
        uint256 poolSize = tempPool.length;

        for (uint256 i = 0; i < winnerCount; i++) {
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(randomness, i))) % poolSize;
            address winner = tempPool[randomIndex];
            
            winners.push(winner);
            participantInfos[winner].isWinner = true;

            tempPool[randomIndex] = tempPool[poolSize - 1];
            poolSize--;
        }

        status = WaffleLib.MarketStatus.REVEALED;
        emit WinnerSelected(winners);
    }
    
    // Reveal 타임아웃
    function cancelByTimeout() external nonReentrant {
        if (status != WaffleLib.MarketStatus.COMMITTED) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.COMMITTED);
        
        if (block.timestamp > revealDeadline) {
            status = WaffleLib.MarketStatus.FAILED;
            emit MarketFailed("Reveal Timeout");
        } else {
            revert WaffleLib.TimeNotReached();
        }
    }
    
    // Phase 5: 정산
    function confirmReceipt() external nonReentrant {
        WaffleLib.ParticipantInfo storage info = participantInfos[msg.sender];

        if (status != WaffleLib.MarketStatus.REVEALED) 
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.REVEALED);
        if (!info.isWinner) 
            revert WaffleLib.Unauthorized();
        
        if (info.depositRefunded) 
            revert WaffleLib.Unauthorized();
        info.depositRefunded = true;

        if (mType == WaffleLib.MarketType.LOTTERY) {
            uint256 payout = prizePool + PARTICIPANT_DEPOSIT;
            prizePool = 0;
            status = WaffleLib.MarketStatus.COMPLETED;
            _safeTransferETH(msg.sender, payout);
            emit MarketCompleted();
        } else {
            _safeTransferETH(msg.sender, PARTICIPANT_DEPOSIT);

            if (prizePool > 0 || sellerDeposit > 0) {
                uint256 totalPayout = prizePool + sellerDeposit;
                prizePool = 0;
                sellerDeposit = 0;
                status = WaffleLib.MarketStatus.COMPLETED;
                
                _safeTransferETH(seller, totalPayout);
                emit MarketCompleted();
            }
        }
    }
    
    // 환불
    function claimRefund() external nonReentrant {
        WaffleLib.ParticipantInfo storage info = participantInfos[msg.sender];
        
        if (!info.hasEntered || info.depositRefunded) 
            revert WaffleLib.Unauthorized();

        uint256 refundAmount = 0;

        if (status == WaffleLib.MarketStatus.FAILED) {
            refundAmount = info.paidAmount;
        } 
        else if (status >= WaffleLib.MarketStatus.REVEALED && !info.isWinner) {
            refundAmount = PARTICIPANT_DEPOSIT;
        }

        if (refundAmount > 0) {
            info.depositRefunded = true;
            _safeTransferETH(msg.sender, refundAmount);
        }
    }
    
    // 조회 함수들
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }
    
    function getWinners() external view returns (address[] memory) {
        return winners;
    }
    
    function _safeTransferETH(address to, uint256 value) internal {
        if (value == 0) return;
        (bool success, ) = to.call{value: value}("");
        if (!success) revert WaffleLib.TransferFailed();
    }
}