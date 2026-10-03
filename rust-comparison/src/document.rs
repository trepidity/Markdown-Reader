use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};
use thiserror::Error;
pub const MAX_SIZE: usize = 16 << 20;
#[derive(Debug, Error)]
pub enum Error {
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("open a regular UTF-8 file without NUL, at most 16 MiB")]
    InvalidFile,
    #[error("file changed outside the app; draft retained. Save Copy or Reload to resolve")]
    Conflict,
    #[error("stale editor command rejected")]
    Stale,
    #[error("{0}")]
    Command(&'static str),
}
#[derive(Debug)]
pub struct Document {
    pub path: PathBuf,
    pub text: String,
    saved: String,
    pub revision: u64,
    history: Vec<String>,
    index: usize,
}
fn read(path: &Path) -> Result<String, Error> {
    let file = fs::File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(Error::InvalidFile);
    }
    let mut text = String::new();
    file.take((MAX_SIZE + 1) as u64).read_to_string(&mut text)?;
    if text.len() > MAX_SIZE || text.contains('\0') {
        return Err(Error::InvalidFile);
    }
    Ok(text)
}
impl Document {
    pub fn open(path: &Path) -> Result<Self, Error> {
        let path = path.canonicalize()?;
        let text = read(&path)?;
        Ok(Self {
            path,
            saved: text.clone(),
            history: vec![text.clone()],
            text,
            revision: 1,
            index: 0,
        })
    }
    pub fn dirty(&self) -> bool {
        self.text != self.saved
    }
    pub fn can_undo(&self) -> bool {
        self.index > 0
    }
    pub fn can_redo(&self) -> bool {
        self.index + 1 < self.history.len()
    }
    pub fn edit(&mut self, text: String, revision: u64) -> Result<(), Error> {
        if revision != self.revision {
            return Err(Error::Stale);
        }
        if text != self.text {
            self.history.truncate(self.index + 1);
            self.history.push(text.clone());
            self.index += 1;
            self.text = text;
            self.revision += 1;
            let mut bytes: usize = self.history.iter().map(String::len).sum();
            while self.history.len() > 2 && (bytes > 32 << 20 || self.history.len() > 500) {
                bytes -= self.history.remove(0).len();
                self.index -= 1;
            }
        }
        self.save()
    }
    pub fn history(&mut self, redo: bool) -> Result<(), Error> {
        if redo && self.can_redo() {
            self.index += 1;
        }
        if !redo && self.can_undo() {
            self.index -= 1;
        }
        self.text.clone_from(&self.history[self.index]);
        self.revision += 1;
        self.save()
    }
    pub fn save(&mut self) -> Result<(), Error> {
        if !self.dirty() {
            return Ok(());
        }
        if self.text.len() > MAX_SIZE || self.text.contains('\0') {
            return Err(Error::InvalidFile);
        }
        if read(&self.path)? != self.saved {
            return Err(Error::Conflict);
        }
        let parent = self.path.parent().ok_or(Error::InvalidFile)?;
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        temp.as_file()
            .set_permissions(fs::metadata(&self.path)?.permissions())?;
        temp.write_all(self.text.as_bytes())?;
        temp.as_file().sync_all()?;
        // Recheck after writing the temporary file. Like the Go baseline, this is
        // optimistic conflict detection, not an OS-level compare-and-swap.
        if read(&self.path)? != self.saved {
            return Err(Error::Conflict);
        }
        temp.persist(&self.path).map_err(|e| e.error)?;
        self.saved.clone_from(&self.text);
        Ok(())
    }
    pub fn save_copy(&mut self, path: &Path) -> Result<(), Error> {
        if self.text.len() > MAX_SIZE {
            return Err(Error::InvalidFile);
        }
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        temp.write_all(self.text.as_bytes())?;
        temp.as_file().sync_all()?;
        temp.persist_noclobber(path).map_err(|e| e.error)?;
        self.path = path.canonicalize()?;
        self.saved.clone_from(&self.text);
        self.revision += 1;
        Ok(())
    }
    pub fn reload(&mut self) -> Result<(), Error> {
        let mut next = Self::open(&self.path)?;
        next.revision = self.revision + 1;
        *self = next;
        Ok(())
    }
}
