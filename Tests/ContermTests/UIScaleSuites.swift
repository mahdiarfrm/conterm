import Testing

/// Parent of every suite that writes `conterm.uiScale` and reloads the
/// shared scale. A suite's own `.serialized` only orders its own tests, so
/// two such suites could still run at once and change the scale under each
/// other. On the parent, `.serialized` reaches every nested suite: their
/// tests run one at a time, across suites as well as within them.
@Suite(.serialized) enum UIScaleSuites {}
