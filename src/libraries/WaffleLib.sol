// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library WaffleLib {

    // 복권과 래플을 구분
    enum MarketType { LOTTERY, RAFFLE }

    enum MarketStatus {
        CREATED,        // 생성됨
        OPEN,           // 응모 진행 중
        CLOSED,         // 마감됨 (추첨 대기)
        COMMITTED,      // 비밀값 제출됨
        REVEALED,       // 당첨자 확정 (정산 대기)
        COMPLETED,      // 정산 완료
        FAILED          // 목표 미달 또는 타임아웃
    }

    struct Market {
        uint256 id;
        address seller;
        MarketType mType;
        
        // 경제 모델
        uint256 ticketPrice;
        uint256 depositPerEntry;  // 참여자 보증금 (0.005 ETH)
        uint256 sellerDeposit;    // 판매자 보증금 (Raffle only)
        uint256 prizePool;        // 95% 누적된 상금
        
        // 조건
        uint256 goalAmount;       // Lottery 목표액
        uint256 preparedQuantity; // Raffle 준비 수량
        uint256 endTime;
        
        // 상태
        MarketStatus status;
        address[] participants;
        address[] winners;
        
        // 난수 생성 (수정됨)
        uint256 snapshotBlock;    // closeEntries에서 설정 (block.number + 100)
        bytes32 commitment;       // hash(secret + nonce)
        uint256 nonce;            // 추가 엔트로피
        uint256 revealDeadline;   // Reveal 제한 시간 (타임아웃용)
        uint256 nullifierHashSum; // XOR 누적값
    }

    struct ParticipantInfo {
        bool hasEntered;
        bool isWinner;
        uint256 paidAmount;       // 티켓값 + 보증금 (환불 기준)
        bool depositRefunded;
    }

    // Errors
    error InvalidState(MarketStatus current, MarketStatus expected);
    error InsufficientFunds();
    error AlreadyParticipated();
    error TimeNotReached();
    error TimeExpired();
    error Unauthorized();
    error VerificationFailed();
    error TransferFailed();
    error GoalNotReached();
}