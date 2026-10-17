# frozen_string_literal: true

module SpecrelayRunner
  EvidenceImageInstructions = <<~TEXT.freeze
    Evidence screenshots, including temporary browser captures:
    - Save JPEG (.jpg) at quality 65 and CSS-pixel scale when supported.
    - Every image must be strictly smaller than 200,000 bytes. Measure the encoded file
      before any agent image read, evidence attachment or Git publication.
    - If too large, recapture narrower regions or split a long page into readable sections
      at quality 65. Preserve the context and displayed values that establish the result.
    - Open the final images and check that relevant text, numbers, status and tested result remain readable.
      If size and readability cannot both be met, report evidence as blocked.
    - Keep only compliant images in evidence attachments and Git, without oversized originals.
      Normalize temporary captures before image reads and report the size and readability check briefly.
  TEXT
end
