# 绘生音效来源

本目录保存游戏实际引用的18个音效和4首音乐。原始素材保留在原位置；这里只复制选中的文件，未修改音频内容。

## 音效

以下音效来源均标注 CC0。四套 Kenney 的许可文本保存在 `licenses/`，铅笔音效的来源页及许可链接如下。

| 游戏文件 | 原始文件 | 来源 |
| --- | --- | --- |
| ui_click.ogg | click_003.ogg | Kenney Interface Sounds |
| ui_cancel.ogg | back_001.ogg | Kenney Interface Sounds |
| ui_confirm.ogg | confirmation_002.ogg | Kenney Interface Sounds |
| income.ogg | drop_001.ogg | Kenney Interface Sounds |
| hit_01.ogg / hit_02.ogg | impactSoft_medium_000.ogg / 001.ogg | Kenney Impact Sounds |
| death.ogg | impactSoft_heavy_000.ogg | Kenney Impact Sounds |
| core_hit.ogg | impactPunch_medium_000.ogg | Kenney Impact Sounds |
| shoot_01.ogg / shoot_02.ogg | laserSmall_000.ogg / 002.ogg | Kenney Sci-fi Sounds |
| shoot_heavy.ogg / shoot_scatter.ogg | laserSmall_004.ogg / 003.ogg | Kenney Sci-fi Sounds |
| grow.ogg | slime_000.ogg | Kenney Sci-fi Sounds |
| stage.ogg | jingles_PIZZI06.ogg | Kenney Music Jingles |
| evolve.ogg | jingles_PIZZI03.ogg | Kenney Music Jingles |
| victory.ogg / defeat.ogg | jingles_PIZZI07.ogg / 10.ogg | Kenney Music Jingles |
| paper.mp3 | 277312__elliotlp__pencil-writing-on-paper.mp3 | elliotlp — Pencil Writing on Paper |

来源：

- [Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds)
- [Kenney Impact Sounds](https://kenney.nl/assets/impact-sounds)
- [Kenney Sci-fi Sounds](https://kenney.nl/assets/sci-fi-sounds)
- [Kenney Music Jingles](https://kenney.nl/assets/music-jingles)
- [elliotlp — Pencil Writing on Paper](https://freesound.org/people/elliotlp/sounds/277312/)
- [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)

片段时长、音量和音高变化在 SoundBank 资源中配置，不依赖外部音频编辑程序。

## 用户提供的章节与战斗音乐

2026年10月19日从项目父目录复制。以下音乐不适用上述免费音效的CC0声明，来源记录按交付文件名保留。

| 游戏文件 | 交付文件 | 使用位置 |
| --- | --- | --- |
| music/chapter_1.mp3 | 第一章音乐.mp3 | CG1 |
| music/chapter_2.mp3 | 第二章音乐·.mp3 | CG2 |
| music/chapter_3.mp3 | 第三章音乐.mp3 | CG3及结尾CG4 |
| music/battle.mp3 | 局内战斗音乐.mp3 | 三关局内 |

四首音乐均按原文件复制，循环通过Godot导入设置启用；章节和战斗的混音电平配置在 `resources/audio/music_library.tres`。
