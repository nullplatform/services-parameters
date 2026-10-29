import pathlib, re, sys

# Fails while the repository still carries the template's placeholders: they look
# valid, so nothing else stops a release that would publish them to the catalog.
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
problems = []

def field(text, key):
    m = re.search(r'"%s"\s*:\s*"([^"]*)"' % key, text)
    return m.group(1) if m else None

def selectors(text):
    i = text.find('"selectors"')
    if i < 0:
        return None
    block = text[i:text.find("}", i)]
    return {k: field(block, k) for k in ("category", "sub_category", "provider")}

for d in ("my-service", "my-scope"):
    if (root / d).is_dir():
        problems.append(f"directory {d}/ is still the template's: git mv it to your slug (README, Start here)")

for wf in ("release.yml", "beta.yml", "trivy.yml"):
    p = root / ".github" / "workflows" / wf
    if p.is_file() and re.search(r"image_name:.*\bmy-(service|scope)\b", p.read_text()):
        problems.append(f".github/workflows/{wf}: image_name still says my-service/my-scope")

for spec in sorted(root.glob("**/specs/service-spec.json.tpl")) + sorted(root.glob("**/specs/links/*.json.tpl")):
    if ".git" in spec.parts:
        continue
    rel = spec.relative_to(root)
    text = spec.read_text()
    if spec.name == "service-spec.json.tpl" and field(text, "name") in ("My Service", "My Scope"):
        problems.append(f"{rel}: name is still the template's ({field(text, 'name')})")
    s = selectors(text)
    if s and s["category"] == "Other" and s["sub_category"] == "Other":
        problems.append(f"{rel}: selectors still the template's (category and sub_category = Other)")
    if s and s["sub_category"] == "My Scope":
        problems.append(f"{rel}: selectors.sub_category still the template's (My Scope)")

for p in problems:
    print(f"::error::{p}")
sys.exit(1 if problems else 0)
