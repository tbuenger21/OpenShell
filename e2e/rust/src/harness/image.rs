// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Image references shared by published-image E2E tests.

/// Fallback used when E2E runs outside the release script.
///
/// Keep this aligned with `openshell_core::image::DEFAULT_COMMUNITY_BASE_IMAGE`.
pub const DEFAULT_SANDBOX_IMAGE: &str =
    "ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:d446c17105e7448e602238a8a5a4ddd0233c071082406522f81c31f8b1309525";

/// Return the sandbox base selected by the release, or the checked-in default.
pub fn sandbox_image() -> String {
    std::env::var("OPENSHELL_SANDBOX_IMAGE")
        .unwrap_or_else(|_| DEFAULT_SANDBOX_IMAGE.to_string())
}
