// Common marker for errors raised while preparing a profile's shared configuration.
//
// Each store (MCP, configuration parity, projects, history) has its own error enum with a
// user-facing Japanese description. The launcher only needs to know "this is a known
// preparation error, show its description", so it checks this one protocol instead of
// listing every enum.

import Foundation

/// A preparation error whose `errorDescription` is safe to show to the user as-is.
public protocol SharedPreparationError: LocalizedError {}
