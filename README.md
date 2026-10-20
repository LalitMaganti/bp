# buildprof CI survey

Recordings of other projects' GitHub Actions CI with [buildprof](https://github.com/LalitMaganti/buildprof).
This repository is not affiliated with any of these projects.

Each `.github/workflows/<project>--*.yml` is that project's workflow at the
commit listed in `projects/index.txt`, with Windows and macOS jobs removed and
each bash step run under buildprof. Workflows run only when started by hand,
and each job uploads its recordings as artifacts.
