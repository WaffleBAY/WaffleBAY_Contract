// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library WaffleLib {

    // 복권과 래플을 구분
    enum MarketType { LOTTERY, RAFFLE }

    // 마켓 상태
    enum MarketStatus {
        CREATED,        // 마켓이 생성되었지만 아직 응모를 받지 않는 상태
        OPEN,           // 응모 진행 중
        CLOSED,         // 마감됨, 추첨을 위해 commit/reveal 대기 중
        COMMITTED,      // 운영자가 비밀값의 해시(commitment)를 제출한 상태
        REVEALED,       // 비밀값이 공개되고 당첨자가 확정된 상태 (정산 대기)
        COMPLETED,      // 정산 완료(상금 지급, 보증금 반환)
        FAILED          // 목표 미달 또는 reveal 타임아웃으로 마켓이 실패한 상태
    }

    struct Market {
        uint256 id;         // 마켓 고유 ID, Factory에서 부여
        address seller;     // 마켓 판매자 주소
        MarketType mType;   // 마켓 타입
        
        // 경제 모델
        uint256 ticketPrice;      // 응모 1회당 가격, 티켓 가격 (0.01 ETH)
        uint256 depositPerEntry;  // 참여자 보증금 (0.005 ETH)
        uint256 sellerDeposit;    // 판매자 보증금 (Raffle에서만 사용)
        uint256 prizePool;        // 95% 누적된 상금
        
        // 조건
        uint256 goalAmount;       // Lottery 목표액
        uint256 preparedQuantity; // Raffle 준비 수량
        uint256 endTime;          // 응모 마감 시간 (타임스탬프)
        
        // 상태
        MarketStatus status;        // 현재 마켓 상태
        address[] participants;     // 응모한 참여자들의 주소 배열
        address[] winners;          // 추첨된 당첨자들의 주소 배열
        
        // 난수 생성
        uint256 snapshotBlock;    // closeEntries에서 설정 (block.number + 100)
                                  // 이 블록 이후의 prevrandao를 난수 소스로 사용
        bytes32 commitment;       // hash(secret + nonce)
        uint256 nonce;            // commitment에 포함된 추가 엔트로피 값
        uint256 revealDeadline;   // Reveal 제한 시간 (타임아웃용)
        uint256 nullifierHashSum; // 모든 참여자들의 nullifierHash를 XOR로 누적한 값
    }

    struct ParticipantInfo {
        bool hasEntered;          // 이 주소가 응모했는지 여부 확인
        bool isWinner;            // 당첨자인지 여붕
        uint256 paidAmount;       // 티켓값 + 보증금 (환불 기준)
        bool depositRefunded;     // 중복 환불 방지용
    }

    // Errors

    // 현재 상태와 기대 상태가 불일치할때
    error InvalidState(MarketStatus current, MarketStatus expected);
    // 보내온 ETH가 부족할때
    error InsufficientFunds();
    // 이미 응모한 참여자가 또 응모하려고 할때(nullifierHash 중복)
    error AlreadyParticipated();
    // 응모 마감 시간이 지나지 않았을때
    error TimeNotReached();
    // 제한 시간이 이미 지났을때
    error TimeExpired();
    // 권한이 없는 주소가 호출됐을 때
    error Unauthorized();
    // commit-reveal에서 해시 검증 실패
    error VerificationFailed();
    // 이더 전송 실패
    error TransferFailed();
    // 목표 금액 미달성
    error GoalNotReached();
}