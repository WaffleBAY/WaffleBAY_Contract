# 🧇 Waffle Contracts

**World ID 기반의 시빌 저항(Sybil-Resistant) 래플 & 복권 플랫폼 스마트 컨트랙트입니다.**
World Chain 위에서 동작하며, 사용자의 고유성(Humanity)을 검증하여 공정한 추첨 문화를 만듭니다.

## 🏗 Architecture

이 프로젝트는 **Factory-Market 패턴**을 사용하여 확장성과 유지보수성을 확보했습니다.

### 1. WaffleFactory.sol
- **역할:** `WaffleMarket` 인스턴스를 생성하고 관리하는 관리자 컨트랙트입니다.
- **기능:**
  - 글로벌 설정 관리 (World ID Router, App ID, 수수료 수령 지갑 등)
  - 새로운 마켓(Raffle/Lottery) 배포 (`createMarket`)
  - 생성된 마켓들의 주소 목록 추적 및 인덱싱

### 2. WaffleMarket.sol
- **역할:** 개별 래플/복권의 게임 로직을 담당하는 컨트랙트입니다.
- **기능:**
  - **입장(Enter):** World ID ZK-Proof를 검증하여 1인 1티켓 원칙 준수 (중복 참여 방지)
  - **상태 관리:** 생성(Created) → 오픈(Open) → 마감(Closed) → 추첨(Revealed) → 정산(Completed)
  - **경제 모델:** 티켓 판매금 관리, 플랫폼 수수료(5%) 분배, 판매자 보증금 예치/환불

### 3. Libraries & Interfaces
- **WaffleLib.sol:** 데이터 구조(Struct), 상태(Enum), 에러 정의
- **IWorldID.sol:** Worldcoin IDKit 연동 인터페이스
- **ByteHasher.sol:** World ID 검증용 해시 유틸리티

---

## 🎲 Core Logic: Fair Randomness

블록체인 상의 난수 생성은 예측 가능성의 위험이 있습니다. Waffle은 **조작 불가능한 공정성(Provable Fairness)**을 위해 **Commit-Reveal 스키마**와 **User Entropy**를 결합한 하이브리드 방식을 사용합니다.

1.  **User Entropy (Nullifier Aggregation):**
    - 사용자가 입장(`enter`)할 때마다 고유한 `nullifierHash`가 제출됩니다.
    - 이 값들은 `nullifierHashSum`에 누적(XOR/Add)되어, 마지막 참여자가 누구냐에 따라 난수 시드가 완전히 달라지게 됩니다. (Operator조차 결과 예측 불가)

2.  **Operator Commitment:**
    - 마켓 마감 시, Operator는 미리 생성한 비밀값(Secret)의 해시(`commitment`)를 온체인에 제출합니다.

3.  **Reveal & Derivation:**
    - 추첨 단계에서 Operator가 비밀값을 공개합니다.
    - **최종 난수 산출:**
      ```solidity
      uint256 randomness = keccak256(
          abi.encode(operatorSecret, nullifierHashSum, blockhash(snapshotBlock))
      );
      uint256 winnerIndex = randomness % participants.length;
      ```
    - 이 방식은 **운영자의 조작**과 **채굴자의 블록 조작**을 모두 방지합니다.