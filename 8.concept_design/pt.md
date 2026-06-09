# 메인 페이지

# 목차
  1. CUBRID HA 복제 구조
  2. applylogdb의 특성
  3. 병렬 applylogdb가 필요한 이유
  4. PoC 구조와 결과
  5. PoC 이후의 핵심 과제
  6. 타 DBMS 병렬 복제 사례
  7. 채택 모델: MySQL식 Coordinator 구조
  8. CUBRID 병렬화 전체 설계
  9. 의존성 판단 방식
  10. 슬레이브 Coordinator 동작 방식
  11. 정확성 시나리오
  12. 재시작과 Progress 관리
  13. 결론 및 향후 과제

# 1. CUBRID HA 복제 구조
## 1-1. Cubrid HA 구조도 (p.3)
## 1-2. APPLYLOGDB의 복제 과정(p.4 ~ p.8)
   final_lsa, commited_lsa 를 이용한 복제 과정 설명, 왼쪽에는 페이지와 Lsa 아이템들, 오른쪽에는 item을 읽어 만든 링크드 리스트 마지막은 commit 아이템을 만났을때 서버로 apply 후 commited_lsa를 이동하는 모습
## 1-3. 잠깐 로지컬 복제 피지컬 복제 설명(p.9)
# 3. 병렬 applylogdb가 필요한 이유(p.10)
# 4. PoC 구조와 결과(p.11)
# 5. PoC 이후의 핵심 과제(
# 6. 타 DBMS 병렬 복제 사례
# 7. 채택 모델: MySQL식 Coordinator 구조
# 8. CUBRID 병렬화 전체 설계
# 9. 의존성 판단 방식
# 10. 슬레이브 Coordinator 동작 방식
# 11. 정확성 시나리오
# 12. 재시작과 Progress 관리
# 13. 결론 및 향후 과제
