;;ERROR CODES
(define-constant err-not-contract-owner (err u100))
(define-constant err-untrusted-oracle (err u101))
(define-constant err-stale-data (err u102))
(define-constant err-unauthorised (err u2001))
(define-constant err-dlc-already-added (err u2002))
(define-constant err-unknown-dlc (err u2003))
(define-constant err-not-reached-closing-time (err u2004))
(define-constant err-already-closed (err u2005))
(define-constant err-already-passed-closing-time (err u2006))
(define-constant err-not-closed (err u2007))
(define-constant err-not-the-same-assets (err u2008))

;;CONTRACT OWNER
(define-constant contract-owner tx-sender)

;; A map of all trusted oracles, indexed by their 33 byte compressed public key.
(define-map trusted-oracles (buff 33) bool)

;;NFT to keep track of the open dlcs easily
(define-non-fungible-token open-dlc (buff 8))

(define-map dlcs
	(buff 8)
	{
    uuid: (buff 8),
    asset: (buff 32),
    closing-time: uint,  ;;seconds because stacks block has the timestamp in seconds
    closing-price: (optional uint), ;; none means it is still open
    actual-closing-time: uint,
    emergency-refund-time: uint,
    creator: principal
	})

(define-read-only (get-last-block-timestamp)
  (default-to u0 (get-block-info? time (- block-height u1))))

(define-read-only (get-dlc (uuid (buff 8)))
  (map-get? dlcs uuid))

;;opens a new dlc
(define-public (open-new-dlc (uuid (buff 8)) (asset (buff 32)) (closing-time uint) (emergency-refund-time uint) (creator principal))
  (begin
    (asserts! (is-eq contract-owner tx-sender) err-unauthorised)
    (asserts! (is-none (map-get? dlcs uuid)) err-dlc-already-added)
    (map-set dlcs uuid {
      uuid: uuid, 
      asset: asset, 
      closing-time: closing-time, 
      closing-price: none, 
      actual-closing-time: u0, 
      emergency-refund-time: emergency-refund-time,
      creator: creator })
    (print {
      uuid: uuid, 
      asset: asset, 
      closing-time: closing-time,
      emergency-refund-time: emergency-refund-time,
      creator: creator })
    (nft-mint? open-dlc uuid .discreet-log-storage-v5))) ;;mint an open-dlc nft to keep track of open dlcs

;;emits an event
(define-public (create-dlc (uuid (buff 8)) (asset (buff 32)) (closing-time uint) (emergency-refund-time uint))
  (begin 
    (print {
      uuid: uuid,
      asset: asset, 
      closing-time: closing-time, 
      emergency-refund-time: emergency-refund-time,
      creator: tx-sender})
    (ok true)))

;;normal dlc close
(define-public (close-dlc (uuid (buff 8)) (timestamp uint) (entries (list 10 {symbol: (buff 32), value: uint})) (signature (buff 65)))
  (let (
    ;; Recover the pubkey of the signer.
		(signer (try! (contract-call? 'STDBEG5X8XD50SPM1JJH0E5CTXGDV5NJTJTTH7YB.redstone-verify recover-signer timestamp entries signature)))
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    (block-timestamp (get-last-block-timestamp))
    )
    ;; Check if the signer is a trusted oracle.
		(asserts! (is-trusted-oracle signer) err-untrusted-oracle)
		;; Check if the data is not stale, depending on how the app is designed.
		(asserts! (> timestamp block-timestamp) err-stale-data) ;; timestamp should be larger than the last block timestamp.
    ;;DLC related checks
    (asserts! (is-eq (unwrap-panic (get symbol (element-at entries u0))) (get asset dlc)) err-not-the-same-assets) ;;check if the submitted asset is the same what was logged in the DLC
    (asserts! (>= block-timestamp (get closing-time dlc)) err-not-reached-closing-time) ;;dlc not reached closing time
    (asserts! (is-none (get closing-price dlc)) err-already-closed)
    (asserts! (or (is-eq contract-owner tx-sender) (is-eq (get creator dlc) tx-sender)) err-unauthorised)
    (map-set dlcs uuid (merge dlc { closing-price: (get value (element-at entries u0)), actual-closing-time: (/ timestamp u1000) })) ;;timestamp is in milliseconds so we have to convert it to seconds to keep the timestamps consistent
    (print {
      uuid: uuid,
      closing-price: (get value (element-at entries u0)),
      actual-closing-time: (/ timestamp u1000)})
    (nft-burn? open-dlc uuid .discreet-log-storage-v5))) ;;burn the open-dlc nft related to the UUID


;;early dlc close
(define-public (early-close-dlc (uuid (buff 8)) (timestamp uint) (entries (list 10 {symbol: (buff 32), value: uint})) (signature (buff 65)))
  (let (
    ;; Recover the pubkey of the signer.
		(signer (try! (contract-call? 'STDBEG5X8XD50SPM1JJH0E5CTXGDV5NJTJTTH7YB.redstone-verify recover-signer timestamp entries signature)))
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    (block-timestamp (get-last-block-timestamp))
    )
    ;; Check if the signer is a trusted oracle.
		(asserts! (is-trusted-oracle signer) err-untrusted-oracle)
		;; Check if the data is not stale, depending on how the app is designed.
		(asserts! (> timestamp block-timestamp) err-stale-data) ;; timestamp should be larger than the last block timestamp.
    ;;DLC related checks
    (asserts! (is-eq (unwrap-panic (get symbol (element-at entries u0))) (get asset dlc)) err-not-the-same-assets) ;;check if the submitted asset is the same what was logged in the DLC
    (asserts! (< block-timestamp (get closing-time dlc)) err-already-passed-closing-time) ;;DLC passed the closing time so can't be closed early
    (asserts! (is-none (get closing-price dlc)) err-already-closed)
    (asserts! (or (is-eq contract-owner tx-sender) (is-eq (get creator dlc) tx-sender)) err-unauthorised)
    (map-set dlcs uuid (merge dlc { closing-price: (get value (element-at entries u0)), actual-closing-time: (/ timestamp u1000) })) ;;timestamp is in milliseconds so we have to convert it to seconds to keep the timestamps consistent
    (print {
      uuid: uuid,
      closing-price: (get value (element-at entries u0)),
      actual-closing-time: (/ timestamp u1000)})
    (nft-burn? open-dlc uuid .discreet-log-storage-v5))) ;;burn the open-dlc nft related to the UUID

;; get the closing price of the DLC by UUID
(define-read-only (get-dlc-closing-price-and-time (uuid (buff 8)))
(let (
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    )
    (asserts! (is-some (get closing-price dlc)) err-not-closed)
    (ok {
      closing-price: (get closing-price dlc),
      closing-time: (get closing-time dlc)
    })))


(define-read-only (is-trusted-oracle (pubkey (buff 33)))
	(default-to false (map-get? trusted-oracles pubkey))
)

;; #[allow(unchecked_data)]
(define-public (set-trusted-oracle (pubkey (buff 33)) (trusted bool))
	(begin
		(asserts! (is-eq contract-owner tx-sender) err-not-contract-owner)
		(ok (map-set trusted-oracles pubkey trusted))
	)
)