basis/  (앱에 늘 들어 있음, 지우지 말 것)
  basis_transcoder.js · basis_transcoder.wasm — KTX2(Basis) 텍스처를 푸는 트랜스코더. three@0.170.0 패키지의
  examples/jsm/libs/basis/ 에서 그대로 복사한 것. three 버전을 올리면 같은 버전의 것으로 바꿔 넣는다.
  없으면 뷰어가 three 를 받은 곳(CDN)의 것을 쓴다.

오프라인 시연용 로컬 사본 (선택). 여기에 파일이 있으면 앱이 CDN 대신 이것을 쓴다.

필요한 구조:
  vendor/three/build/three.module.js            (+ 같은 폴더의 three.core.js 가 있으면 함께)
  vendor/three/examples/jsm/...                 (three 패키지의 examples/jsm 폴더 통째로)
  vendor/gaussian-splats-3d/gaussian-splats-3d.module.js

받는 방법 (노트북에서):
  npm pack three@0.170.0 @mkkellogg/gaussian-splats-3d@0.4
  tar xzf three-0.170.0.tgz && mkdir -p three && cp -R package/build package/examples three/ && rm -rf package
  tar xzf mkkellogg-gaussian-splats-3d-*.tgz && mkdir -p gaussian-splats-3d && cp package/build/gaussian-splats-3d.module.js gaussian-splats-3d/
