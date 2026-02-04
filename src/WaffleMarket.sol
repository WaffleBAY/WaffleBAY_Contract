// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
// 명시적 Import 사용
import { IWorldID } from "./interfaces/IWorldID.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleMarket is ReentrancyGuard, Ownable {
    

    IWorldID public immutable worldId;
    uint256 public immutable externalNullifier;
    
    address public worldFoundation; 
    address public opsWallet;

    uint256 public marketCount;
    mapping(uint256 => WaffleLib.Market) public markets;
    mapping(uint256 => mapping(address => WaffleLib.ParticipantInfo)) public participantInfos;
    mapping(uint256 => mapping(uint256 => bool)) public nullifierHashes;

    uint256 public constant PARTICIPANT_DEPOSIT = 0.005 ether;
    uint256 public constant REVEAL_TIMEOUT = 1 days;

    event MarketCreated(uint256 indexed id, address seller, WaffleLib.MarketType mType);
    event MarketOpen(uint256 indexed id);
    event Entered(uint256 indexed id, address participant);
    event WinnerSelected(uint256 indexed id, address[] winners);
    event MarketCompleted(uint256 indexed id);
    event MarketFailed(uint256 indexed id, string reason);

    constructor(
        address _worldId, 
        string memory _appId, 
        address _worldFoundation,
        address _opsWallet
    ) Ownable(msg.sender) { 
        worldId = IWorldID(_worldId);
        // ByteHasher 라이브러리 직접 호출
        externalNullifier = ByteHasher.hashToField(abi.encodePacked(_appId));
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
    }

    // 마켓 생성 단계
    function createMarket(
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration
    ) external payable nonReentrant returns (uint256) {
        // Lottery와 Raffle 분기
        if (_mType == WaffleLib.MarketType.RAFFLE) {
            // Raffle일 경우에 15% 보증금을 요구
            uint256 requiredDeposit = (_goalAmount * 15) / 100;
            if (msg.value < requiredDeposit) revert WaffleLib.InsufficientFunds();
        } else {
            if (msg.value > 0) revert WaffleLib.InsufficientFunds(); 
        }

        uint256 newId = ++marketCount;
        WaffleLib.Market storage m = markets[newId];
        
        m.id = newId;
        m.seller = msg.sender;
        m.mType = _mType;
        m.ticketPrice = _ticketPrice;
        m.depositPerEntry = PARTICIPANT_DEPOSIT;
        m.goalAmount = _goalAmount;
        m.preparedQuantity = _preparedQuantity;
        m.sellerDeposit = msg.value;
        m.endTime = block.timestamp + _duration;
        m.status = WaffleLib.MarketStatus.CREATED;

        emit MarketCreated(newId, msg.sender, _mType);
        return newId;
    }

    // 응모 단계
    // 판매자가 수동으로 OPEN 상태로 전환
    function openMarket(uint256 _id) external {
        WaffleLib.Market storage m = markets[_id];
        if (msg.sender != m.seller) revert WaffleLib.Unauthorized();
        if (m.status != WaffleLib.MarketStatus.CREATED) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.CREATED);
        
        m.status = WaffleLib.MarketStatus.OPEN;
        emit MarketOpen(_id);
    }

    // world ID 검증, 참가자 등록
    function enter(
        uint256 _id,
        uint256 _root,
        uint256 _nullifierHash,
        uint256[8] calldata _proof
    ) external payable nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        
        if (m.status != WaffleLib.MarketStatus.OPEN) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.OPEN);
        if (block.timestamp >= m.endTime) revert WaffleLib.TimeExpired();
        
        uint256 requiredAmount = m.ticketPrice + m.depositPerEntry;
        if (msg.value != requiredAmount) revert WaffleLib.InsufficientFunds();

        if (nullifierHashes[_id][_nullifierHash]) revert WaffleLib.AlreadyParticipated();
        
        // WorldID 검증 로직 (배포 시 주석 해제)
        // worldId.verifyProof(_root, 1, ByteHasher.hashToField(abi.encodePacked(msg.sender)), _nullifierHash, externalNullifier, _proof);

        nullifierHashes[_id][_nullifierHash] = true;
        m.participants.push(msg.sender);
        // 각 참가자가 enter()를 호출할때마다 WorldID의 _nullifierHash가 생성
        // XOR 연산을 통해 예측 불가능성 증가
        m.nullifierHashSum ^= _nullifierHash;
        
        participantInfos[_id][msg.sender] = WaffleLib.ParticipantInfo({
            hasEntered: true,
            isWinner: false,
            paidAmount: msg.value,
            depositRefunded: false
        });

        uint256 feeWorld = (m.ticketPrice * 3) / 100;
        uint256 feeOps = (m.ticketPrice * 2) / 100;
        uint256 toPool = m.ticketPrice - feeWorld - feeOps;

        m.prizePool += toPool;
        
        _safeTransferETH(worldFoundation, feeWorld);
        _safeTransferETH(opsWallet, feeOps);

        emit Entered(_id, msg.sender);
    }

    // 마감 단계
    function closeEntries(uint256 _id) external nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        
        if (block.timestamp < m.endTime) revert WaffleLib.TimeNotReached();
        if (m.status != WaffleLib.MarketStatus.OPEN) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.OPEN);

        if (m.mType == WaffleLib.MarketType.LOTTERY) {
            // Lottery 일때
            if (m.prizePool >= m.goalAmount) {
                m.status = WaffleLib.MarketStatus.CLOSED;
            } else {
                m.status = WaffleLib.MarketStatus.FAILED;
                emit MarketFailed(_id, "목표 금액에 달성하지 못했습니다.");
            }
        } else {
            // Rapple 일때
            if (m.participants.length > m.preparedQuantity) {
                m.status = WaffleLib.MarketStatus.CLOSED;
            } else {
                // 모두 당첨처리
                m.status = WaffleLib.MarketStatus.REVEALED;
                m.winners = m.participants;
                for(uint i=0; i<m.participants.length; i++){
                    participantInfos[_id][m.participants[i]].isWinner = true;
                }
                emit WinnerSelected(_id, m.winners);
            }
        }
    }

    // 판매자의 private key commit
    function commitSecret(uint256 _id, bytes32 _commitment) external {
        WaffleLib.Market storage m = markets[_id];
        if (m.status != WaffleLib.MarketStatus.CLOSED) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.CLOSED);
        if (msg.sender != m.seller) revert WaffleLib.Unauthorized();
        
        m.commitment = _commitment;
        m.status = WaffleLib.MarketStatus.COMMITTED;
        // 최소 100개 블록 이후에 공개되도록 설정
        m.revealStartBlock = block.number;
        m.revealDeadline = block.timestamp + REVEAL_TIMEOUT;
    }

    function revealAndPickWinner(uint256 _id, uint256 _secret) external nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        if (m.status != WaffleLib.MarketStatus.COMMITTED) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.COMMITTED);
        // 100 block 대기 후에 reveal 가능
        if (block.number < m.revealStartBlock + 100) revert WaffleLib.TimeNotReached();
        // 타임아웃 검증
        if (block.timestamp > m.revealDeadline) revert WaffleLib.TimeExpired();

        // 판매자가 비밀 숫자를 선택, 해시해서 블록체인에 저장
        if (keccak256(abi.encodePacked(_secret)) != m.commitment) revert WaffleLib.VerificationFailed();

        // block.prevrandao + secret + nullifierHashSum 조합으로 난수 생성
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            block.prevrandao, 
            _secret, 
            m.nullifierHashSum
        )));

        uint256 winnerCount = (m.mType == WaffleLib.MarketType.LOTTERY) ? 1 : m.preparedQuantity;
        if (winnerCount > m.participants.length) winnerCount = m.participants.length;

        address[] memory tempPool = m.participants;
        uint256 poolSize = tempPool.length;

        for (uint256 i = 0; i < winnerCount; i++) {
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(randomness, i))) % poolSize;
            address winner = tempPool[randomIndex];
            
            m.winners.push(winner);
            participantInfos[_id][winner].isWinner = true;

            tempPool[randomIndex] = tempPool[poolSize - 1];
            poolSize--;
        }

        m.status = WaffleLib.MarketStatus.REVEALED;
        emit WinnerSelected(_id, m.winners);
    }
    
    // 타임아웃 시 FAILED 처리
    function cancelByTimeout(uint256 _id) external nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        if (m.status != WaffleLib.MarketStatus.COMMITTED) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.COMMITTED);
        
        // 타임아웃 확인
        if (block.timestamp > m.revealDeadline) {
            // 타임아웃이면 마켓 실패 처리
            m.status = WaffleLib.MarketStatus.FAILED;
            emit MarketFailed(_id, "Reveal Timeout");
        } else {
            revert WaffleLib.TimeNotReached();
        }
    }

    // 당첨자가 수령 확인되면 정산
    function confirmReceipt(uint256 _id) external nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        WaffleLib.ParticipantInfo storage info = participantInfos[_id][msg.sender];

        if (m.status != WaffleLib.MarketStatus.REVEALED) revert WaffleLib.InvalidState(m.status, WaffleLib.MarketStatus.REVEALED);
        if (!info.isWinner) revert WaffleLib.Unauthorized();
        
        if (info.depositRefunded) revert WaffleLib.Unauthorized();
        info.depositRefunded = true;

        if (m.mType == WaffleLib.MarketType.LOTTERY) {
            uint256 payout = m.prizePool + m.depositPerEntry;
            m.prizePool = 0;
            m.status = WaffleLib.MarketStatus.COMPLETED;
            _safeTransferETH(msg.sender, payout);
            emit MarketCompleted(_id);
        } else {
            _safeTransferETH(msg.sender, m.depositPerEntry);

            if (m.prizePool > 0 || m.sellerDeposit > 0) {
                uint256 totalPayout = m.prizePool + m.sellerDeposit;
                m.prizePool = 0;
                m.sellerDeposit = 0;
                m.status = WaffleLib.MarketStatus.COMPLETED;
                
                _safeTransferETH(m.seller, totalPayout);
                emit MarketCompleted(_id);
            }
        }
    }

    // 미당첨자, 실패시 환불
    function claimRefund(uint256 _id) external nonReentrant {
        WaffleLib.Market storage m = markets[_id];
        WaffleLib.ParticipantInfo storage info = participantInfos[_id][msg.sender];
        
        if (!info.hasEntered || info.depositRefunded) revert WaffleLib.Unauthorized();

        uint256 refundAmount = 0;

        if (m.status == WaffleLib.MarketStatus.FAILED) {
            refundAmount = info.paidAmount; 
        } 
        else if (m.status >= WaffleLib.MarketStatus.REVEALED && !info.isWinner) {
            refundAmount = m.depositPerEntry; 
        }

        if (refundAmount > 0) {
            info.depositRefunded = true;
            _safeTransferETH(msg.sender, refundAmount);
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        if (value == 0) return;
        (bool success, ) = to.call{value: value}("");
        if (!success) revert WaffleLib.TransferFailed();
    }
}