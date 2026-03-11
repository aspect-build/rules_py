use std::{
    ffi::OsStr,
    fmt,
    path::{Component, Path},
};

use miette::{miette, Result};

#[derive(Debug)]
enum BazelGlobSegment {
    Recursive,
    Segment(String),
}

#[derive(Debug)]
pub(crate) struct BazelGlob {
    raw: String,
    segments: Vec<BazelGlobSegment>,
}

impl BazelGlob {
    pub(crate) fn parse(pattern: &str) -> Result<Self> {
        if pattern.is_empty() {
            return Err(miette!(
                "Error in glob: invalid glob pattern '{}': pattern cannot be empty",
                pattern
            ));
        }

        let segments = pattern
            .split('/')
            .map(|segment| {
                if segment.is_empty() {
                    Err(miette!(
                        "Error in glob: invalid glob pattern '{}': empty segment not permitted",
                        pattern
                    ))
                } else if segment == "**" {
                    Ok(BazelGlobSegment::Recursive)
                } else if segment.contains("**") {
                    Err(miette!(
                        "Error in glob: invalid glob pattern '{}': recursive wildcard must be its own segment",
                        pattern
                    ))
                } else {
                    Ok(BazelGlobSegment::Segment(segment.to_owned()))
                }
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(Self {
            raw: pattern.to_owned(),
            segments,
        })
    }

    pub(crate) fn matches(&self, path: &Path) -> bool {
        let Some(path_segments) = path_segments(path) else {
            return false;
        };
        let mut current = vec![false; self.segments.len() + 1];
        current[0] = true;
        self.propagate_recursive_zero_matches(&mut current);

        for path_segment in path_segments {
            let mut next = vec![false; self.segments.len() + 1];

            for (index, is_reachable) in current.iter().enumerate().take(self.segments.len()) {
                if !is_reachable {
                    continue;
                }

                match &self.segments[index] {
                    BazelGlobSegment::Recursive => {
                        next[index] = true;
                    }
                    BazelGlobSegment::Segment(pattern_segment) => {
                        if matches_bazel_segment(pattern_segment, path_segment) {
                            next[index + 1] = true;
                        }
                    }
                }
            }

            self.propagate_recursive_zero_matches(&mut next);
            current = next;
        }

        current[self.segments.len()]
    }

    // This is the same zero-segment transition Bazel's recursive glob star needs.
    // Applying it once per frontier keeps matching O(pattern_segments * path_segments).
    fn propagate_recursive_zero_matches(&self, states: &mut [bool]) {
        for (index, segment) in self.segments.iter().enumerate() {
            if states[index] && matches!(segment, BazelGlobSegment::Recursive) {
                states[index + 1] = true;
            }
        }
    }
}

impl fmt::Display for BazelGlob {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.raw)
    }
}

fn path_segments(path: &Path) -> Option<Vec<&OsStr>> {
    let mut segments = Vec::new();

    for component in path.components() {
        match component {
            Component::Normal(segment) => segments.push(segment),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }

    Some(segments)
}

fn matches_bazel_segment(pattern: &str, segment: &OsStr) -> bool {
    // Bazel's hidden-file behavior is special: bare `*` matches a dotfile, but
    // compound patterns like `*.py` only match dotfiles when they start with `.`.
    let segment = segment.as_encoded_bytes();

    if segment.first() == Some(&b'.') && pattern != "*" && !pattern.starts_with('.') {
        return false;
    }

    let pattern = pattern.as_bytes();

    let mut pattern_index = 0;
    let mut segment_index = 0;
    let mut star_index = None;
    let mut match_index = 0;

    while segment_index < segment.len() {
        if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            match_index = segment_index;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == segment[segment_index]
        {
            pattern_index += 1;
            segment_index += 1;
        } else if let Some(star_index) = star_index {
            pattern_index = star_index + 1;
            match_index += 1;
            segment_index = match_index;
        } else {
            return false;
        }
    }

    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }

    pattern_index == pattern.len()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::BazelGlob;
    use miette::Result;

    #[test]
    fn recursive_glob_matches_nested_paths() -> Result<()> {
        let glob = BazelGlob::parse("**/tests/**")?;
        assert!(glob.matches(Path::new(
            "lib/python3.11/site-packages/cowsay/tests/test_api.py"
        )));
        assert!(!glob.matches(Path::new(
            "lib/python3.11/site-packages/cowsay/main.py"
        )));
        Ok(())
    }

    #[test]
    fn recursive_glob_matches_zero_segments() -> Result<()> {
        let glob = BazelGlob::parse("**/*.py")?;
        assert!(glob.matches(Path::new("main.py")));
        assert!(glob.matches(Path::new("pkg/main.py")));
        Ok(())
    }

    #[test]
    fn hidden_file_behavior_matches_bazel_rules() -> Result<()> {
        let wildcard = BazelGlob::parse("*")?;
        let compound = BazelGlob::parse("*.py")?;
        let hidden_compound = BazelGlob::parse(".*.py")?;

        assert!(wildcard.matches(Path::new(".env")));
        assert!(!compound.matches(Path::new(".hidden.py")));
        assert!(hidden_compound.matches(Path::new(".hidden.py")));
        Ok(())
    }

    #[test]
    fn invalid_double_star_segment_is_rejected() {
        assert!(BazelGlob::parse("foo**/bar").is_err());
    }

    #[test]
    fn invalid_glob_errors_match_bazel_shape() {
        assert_eq!(
            BazelGlob::parse("").unwrap_err().to_string(),
            "Error in glob: invalid glob pattern '': pattern cannot be empty"
        );
        assert_eq!(
            BazelGlob::parse("foo//bar").unwrap_err().to_string(),
            "Error in glob: invalid glob pattern 'foo//bar': empty segment not permitted"
        );
        assert_eq!(
            BazelGlob::parse("foo**/bar").unwrap_err().to_string(),
            "Error in glob: invalid glob pattern 'foo**/bar': recursive wildcard must be its own segment"
        );
    }
}
