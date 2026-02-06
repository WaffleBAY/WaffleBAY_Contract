// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWorldID } from "./interfaces/IWorldID.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleMarket is ReentrancyGuard {

    // ━━━━━━━━━━━━━━━ 마켓 기본 정보 ━━━━━━━━━━━━━━━
    address public immutable seller;
    address public immutable factory;
    address public immutable worldId;
    uint256 public immutable externalNullifier;

    address public worldFoundation;     // 3% 수수료 → Worldcoin 재단
    address public opsWallet;           // 2% 수수료 → 운영 (WaffleTreasury)
    address public operator;            // 운영자 주소

    // ━━━━━━━━━━━━━━━ 마켓 타입 ━━━━━━━━━━━━━━━
    WaffleLib.MarketType public mType;

    // ━━━━━━━━━━━━━━━ 경제 모델 ━━━━━━━━━━━━━━━
    uint256 public ticketPrice;
    uint256 public constant PARTICIPANT_DEPOSIT = 0.005 ether;
    uint256 public sellerDeposit;       // 판매자 보증금 (LOTTERY/RAFFLE 모두, goalAmount × 15%)
    uint256 public prizePool;           // 티켓 가격의 95% 누적

    // ━━━━━━━━━━━━━━━ 조건 ━━━━━━━━━━━━━━━
    uint256 public goalAmount;          // LOTTERY: 목표 금액 / RAFFLE: 보증금 계산 기준
    uint256 public preparedQuantity;    // RAFFLE 전용: 경품 수량
    uint256 public endTime;             // 응모 마감 시간

    // ━━━━━━━━━━━━━━━ 상태 ━━━━━━━━━━━━━━━
    WaffleLib.MarketStatus public status;
    address[] public participants;
    address[] public winners;

    // ━━━━━━━━━━━━━━━ 난수 생성 (Commit-Reveal) ━━━━━━━━━━━━━━━
    // commitment = hash(sellerNullifierHash + address(this))
    // secret = sellerNullifierHash,  nonce = CA(address(this))
    uint256 public immutable sellerNullifierHash;   // 판매자 World ID nullifierHash
    bytes32 public immutable commitment;            // hash(sellerNullifierHash + CA), 생성 시 자동 계산!
    uint256 public nullifierHashSum;                // 참여자 nullifierHash XOR 누적

    uint256 public snapshotBlock;                   // closeEntries()에서 block.number + 100
    bool public secretRevealed;                     // reveal 완료 여부
    uint256 public snapshotPrevrandao;              // reveal 시점의 prevrandao 저장

    uint256 public constant REVEAL_BLOCK_TIMEOUT = 50;  // snapshotBlock 이후 50블록 내 reveal 필요

    // ━━━━━━━━━━━━━━━ 참가자 정보 ━━━━━━━━━━━━━━━
    mapping(address => WaffleLib.ParticipantInfo) public participantInfos;
    mapping(uint256 => bool) public nullifierHashes;

    // ━━━━━━━━━━━━━━━ 이벤트 ━━━━━━━━━━━━━━━
    event MarketOpen();
    event Entered(address indexed participant);
    event SecretRevealed(uint256 nullifierHash);
    event WinnerSelected(address[] winners);
    event Settled();
    event MarketFailed(string reason);

    // ━━━━━━━━━━━━━━━ 생성자 (Factory가 호출) ━━━━━━━━━━━━━━━
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
        uint256 _duration,
        uint256 _sellerNullifierHash
    ) payable {
        seller = _seller;
        factory = msg.sender;
        worldId = _worldId;
        externalNullifier = ByteHasher.hashToField(abi.encodePacked(_appId));
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
        operator = _operator;

        mType = _mType;
        ticketPrice = _ticketPrice;
        goalAmount = _goalAmount;
        preparedQuantity = _preparedQuantity;

        // 두 타입 모두 판매자 보증금 필요 (goalAmount × 15%)
        uint256 requiredDeposit = (_goalAmount * 15) / 100;
        if (msg.value < requiredDeposit) {
            revert WaffleLib.InsufficientFunds();
        }
        sellerDeposit = msg.value;

        // 🔐 sellerNullifierHash 저장
        sellerNullifierHash = _sellerNullifierHash;

        // 🔐 Commitment 자동 생성: hash(sellerNullifierHash + CA)
        // CA(address(this))는 배포 시점에 확정되므로 생성자에서 계산 가능
        // 이후 변경 불가 (immutable)
        commitment = keccak256(abi.encodePacked(_sellerNullifierHash, address(this)));

        endTime = block.timestamp + _duration;
        status = WaffleLib.MarketStatus.CREATED;
    }

    // ━━━━━━━━━━━━━━━ Modifiers ━━━━━━━━━━━━━━━
    modifier onlySeller() {
        if (msg.sender != seller) revert WaffleLib.Unauthorized();
        _;
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 2: 마켓 오픈
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function openMarket() external onlySeller {
        if (status != WaffleLib.MarketStatus.CREATED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CREATED);

        status = WaffleLib.MarketStatus.OPEN;
        emit MarketOpen();
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 2: 응모
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _nullifierHash, externalNullifier, _proof
        // );

        nullifierHashes[_nullifierHash] = true;
        participants.push(msg.sender);
        nullifierHashSum ^= _nullifierHash;

        participantInfos[msg.sender] = WaffleLib.ParticipantInfo({
            hasEntered: true,
            isWinner: false,
            paidAmount: msg.value,
            depositRefunded: false
        });

        // 수수료 분배: ticketPrice 기준 3% 재단, 2% 운영, 95% Pool
        uint256 feeWorld = (ticketPrice * 3) / 100;
        uint256 feeOps = (ticketPrice * 2) / 100;
        uint256 toPool = ticketPrice - feeWorld - feeOps;

        prizePool += toPool;

        _safeTransferETH(worldFoundation, feeWorld);
        _safeTransferETH(opsWallet, feeOps);

        emit Entered(msg.sender);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 3: 응모 마감
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function closeEntries() external nonReentrant {
        if (block.timestamp < endTime)
            revert WaffleLib.TimeNotReached();
        if (status != WaffleLib.MarketStatus.OPEN)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);

        snapshotBlock = block.number + 100;

        if (mType == WaffleLib.MarketType.LOTTERY) {
            if (prizePool >= goalAmount) {
                // 목표 달성 → CLOSED → Phase 4 진행
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                // 목표 미달 → FAILED
                status = WaffleLib.MarketStatus.FAILED;
                // 판매자 보증금 반환
                uint256 deposit = sellerDeposit;
                sellerDeposit = 0;
                _safeTransferETH(seller, deposit);
                emit MarketFailed("Goal not reached");
            }
        } else {
            // RAFFLE
            if (participants.length > preparedQuantity) {
                // 참여자 > 준비 수량 → 추첨 필요 → Phase 4 진행
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                // 참여자 ≤ 준비 수량 → 전원 당첨! Phase 4 스킵
                status = WaffleLib.MarketStatus.REVEALED;
                winners = participants;
                for (uint256 i = 0; i < participants.length; i++) {
                    participantInfos[participants[i]].isWinner = true;
                }
                emit WinnerSelected(winners);
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: Reveal — 판매자가 World ID 재인증으로 신원 증명
    // 검증: hash(재인증된 nullifierHash + address(this)) == commitment
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function revealSecret(
        uint256 _root,
        uint256 _nullifierHash,
        uint256[8] calldata _proof
    ) external onlySeller {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);

        // snapshotBlock 도달 대기 (100블록)
        if (block.number < snapshotBlock)
            revert WaffleLib.TimeNotReached();

        // 50블록 타임아웃 체크
        if (block.number > snapshotBlock + REVEAL_BLOCK_TIMEOUT)
            revert WaffleLib.TimeExpired();

        // World ID 재인증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _nullifierHash, externalNullifier, _proof
        // );

        // Commitment 검증: hash(nullifierHash + CA) == commitment
        bytes32 computedCommitment = keccak256(abi.encodePacked(_nullifierHash, address(this)));
        if (computedCommitment != commitment)
            revert WaffleLib.VerificationFailed();

        secretRevealed = true;
        snapshotPrevrandao = block.prevrandao;

        emit SecretRevealed(_nullifierHash);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: 추첨
    // 난수 = hash(prevrandao + sellerNullifierHash + participantNullifierSum)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function pickWinners() external nonReentrant {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);
        if (!secretRevealed)
            revert WaffleLib.VerificationFailed();

        uint256 randomness = uint256(keccak256(abi.encodePacked(
            snapshotPrevrandao,
            sellerNullifierHash,
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: Reveal 타임아웃
    // 50블록 내 reveal 실패 → 마켓 취소 + 판매자 보증금 50% 슬래싱
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function cancelByTimeout() external nonReentrant {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);

        // 이미 reveal 완료된 경우 취소 불가
        if (secretRevealed) revert WaffleLib.Unauthorized();

        if (block.number <= snapshotBlock + REVEAL_BLOCK_TIMEOUT)
            revert WaffleLib.TimeNotReached();

        status = WaffleLib.MarketStatus.FAILED;

        // 판매자 보증금 50% 슬래싱
        uint256 slashAmount = sellerDeposit / 2;
        uint256 returnAmount = sellerDeposit - slashAmount;
        sellerDeposit = 0;

        _safeTransferETH(opsWallet, slashAmount);    // 슬래싱분 → 운영
        _safeTransferETH(seller, returnAmount);       // 나머지 50% → 판매자

        emit MarketFailed("Reveal Timeout");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 5: 정산
    // LOTTERY: 95% → 당첨자, 5% → 운영, 판매자 보증금 반환
    // RAFFLE:  Prize Pool 전액 + 판매자 보증금 → 판매자
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function settle() external nonReentrant {
        if (status != WaffleLib.MarketStatus.REVEALED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.REVEALED);

        if (mType == WaffleLib.MarketType.LOTTERY) {
            // LOTTERY 정산
            uint256 winnerPrize = (prizePool * 95) / 100;
            uint256 opsFee = prizePool - winnerPrize;

            _safeTransferETH(winners[0], winnerPrize);
            _safeTransferETH(opsWallet, opsFee);
            _safeTransferETH(seller, sellerDeposit);
        } else {
            // RAFFLE 정산: 판매자에게 Prize Pool 전액 + 보증금 반환
            _safeTransferETH(seller, prizePool + sellerDeposit);
        }

        prizePool = 0;
        sellerDeposit = 0;
        status = WaffleLib.MarketStatus.COMPLETED;
        emit Settled();
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 환불 / 보증금 반환
    // FAILED:    Pool 지분 + 참여자 보증금 반환
    // COMPLETED: 참여자 보증금 반환 (당첨/비당첨 모두)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function claimRefund() external nonReentrant {
        WaffleLib.ParticipantInfo storage info = participantInfos[msg.sender];

        if (!info.hasEntered || info.depositRefunded)
            revert WaffleLib.Unauthorized();

        uint256 refundAmount = 0;

        if (status == WaffleLib.MarketStatus.FAILED) {
            // FAILED: Pool 지분 + 참여자 보증금
            uint256 poolShare = prizePool / participants.length;
            refundAmount = PARTICIPANT_DEPOSIT + poolShare;
        }
        else if (status == WaffleLib.MarketStatus.COMPLETED) {
            // COMPLETED: 참여자 보증금 반환 (당첨자/비당첨자 모두)
            refundAmount = PARTICIPANT_DEPOSIT;
        }

        if (refundAmount == 0) revert WaffleLib.InsufficientFunds();

        info.depositRefunded = true;
        _safeTransferETH(msg.sender, refundAmount);
    }

    // ━━━━━━━━━━━━━━━ 조회 함수 ━━━━━━━━━━━━━━━
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }

    function getWinners() external view returns (address[] memory) {
        return winners;
    }

    // ━━━━━━━━━━━━━━━ 내부 함수 ━━━━━━━━━━━━━━━
    function _safeTransferETH(address to, uint256 value) internal {
        if (value == 0) return;
        (bool success, ) = to.call{value: value}("");
        if (!success) revert WaffleLib.TransferFailed();
    }
}
