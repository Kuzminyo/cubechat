from pathlib import Path
root=Path('D:/projects/cubechat/design-previews/matcha-motion-v4')
text=(root.parent/'matcha-motion-v3/check-preview.cjs').read_text(encoding='utf-8-sig')
text=text.replace('matcha-motion-v3/','matcha-motion-v4/').replace("!==40","!==56").replace("cards:40","cards:56").replace('cat-thanks','cat-morning')
text=text.replace("await page.locator('#pause').click();","await page.locator('#filter-new').click();if(await page.locator('.card:visible').count()!==16)throw Error('New filter');await page.locator('#filter-new').click();if(await page.locator('.card:visible').count()!==56)throw Error('All filter');await page.locator('#pause').click();",1)
(root/'check-preview.cjs').write_text(text,encoding='utf-8')

