use core::fmt;

/// Canonical 19-variant Fail-Closed error taxonomy aligned across Rust Core, Stylus ABI, Solidity, and Reference Verifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ClearingError {
    MathOverflow,
    DivisionByZero,
    InvalidAssetConfig,
    InvalidHaircut,
    StaleMarkPrice,
    BatchCapacityExceeded,
    DuplicateParticipant,
    InvalidObligation,
    UnauthorizedObligation,
    InvalidIntent,
    ExpiredIntent,
    UnauthorizedCaller,
    InvalidSignature,
    NonceAlreadyUsed,
    AssetConservationViolated,
    LimitPriceViolated,
    InsufficientInitialMargin,
    HealthMonotonicityViolated,
    InsufficientWithdrawableBalance,
}

impl ClearingError {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MathOverflow => "MathOverflow",
            Self::DivisionByZero => "DivisionByZero",
            Self::InvalidAssetConfig => "InvalidAssetConfig",
            Self::InvalidHaircut => "InvalidHaircut",
            Self::StaleMarkPrice => "StaleMarkPrice",
            Self::BatchCapacityExceeded => "BatchCapacityExceeded",
            Self::DuplicateParticipant => "DuplicateParticipant",
            Self::InvalidObligation => "InvalidObligation",
            Self::UnauthorizedObligation => "UnauthorizedObligation",
            Self::InvalidIntent => "InvalidIntent",
            Self::ExpiredIntent => "ExpiredIntent",
            Self::UnauthorizedCaller => "UnauthorizedCaller",
            Self::InvalidSignature => "InvalidSignature",
            Self::NonceAlreadyUsed => "NonceAlreadyUsed",
            Self::AssetConservationViolated => "AssetConservationViolated",
            Self::LimitPriceViolated => "LimitPriceViolated",
            Self::InsufficientInitialMargin => "InsufficientInitialMargin",
            Self::HealthMonotonicityViolated => "HealthMonotonicityViolated",
            Self::InsufficientWithdrawableBalance => "InsufficientWithdrawableBalance",
        }
    }
}

impl fmt::Display for ClearingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
