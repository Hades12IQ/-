package com.firas.ai.data

/** Public tier identifiers; upstream provider/model names are selected by the server. */
enum class FirasModelTier(val wire: String, val label: String, val supportsThinking: Boolean) {
    LUMA("mini", "luma 1", false), NOVA("pro", "nova 1", true),
    TITAN("ultra", "titan 1", true), ATLAS("max", "atlas 1", true),
    OMNIX("omnix", "omnix 1", false);
    companion object {
        fun fromWire(value: String): FirasModelTier = entries.firstOrNull { it.wire == value }
            ?: throw FirasFailure(UiNotice("هذا النموذج غير متاح.", "This model is unavailable."), 400, "invalid_model")
    }
}
