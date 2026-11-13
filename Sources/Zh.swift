import Foundation

/// 只用于「比较」的简繁归一。
///
/// 场景：酷我 / 网易云返回简体「周杰伦」，YouTube Music 返回繁体「周傑倫」。
/// 直接比对会把同一首歌判成两个人，严格匹配一开就整批被挡掉。
///
/// 这张表只做单向 繁 → 简，够用即可 —— 目的是让「是不是同一个人 / 同一首歌」
/// 成立，不追求当转换器用，所以没有收录全部繁简字对。
enum Zh {

    private static let tradToSimp: [Character: Character] = {
        let raw = """
        傑杰 倫伦 陳陈 鄧邓 羅罗 劉刘 楊杨 黃黄 吳吴 許许 謝谢 葉叶 蕭萧 孫孙 鍾钟
        賴赖 莊庄 盧卢 譚谭 鄭郑 張张 偉伟 馮冯 鄒邹 賈贾 韓韩 顧顾 龔龚 趙赵 錢钱
        蔣蒋 呂吕 嚴严 華华 蘇苏 範范 魯鲁 韋韦 馬马 鳳凤 龍龙 萬万 齊齐 龐庞 顏颜
        歐欧 陽阳 陰阴 雙双 邊边 關关 東东 樂乐 喬乔 雲云 靈灵 風风 飛飞 車车 貝贝
        費费 賀贺 賽赛 時时 愛爱 戀恋 夢梦 淚泪 憶忆 懷怀 願愿 緣缘 紅红 藍蓝 場场
        歲岁 歷历 經经 過过 還还 這这 說说 話话 語语 記记 誰谁 讓让 變变 聲声 聽听
        寫写 讀读 書书 開开 間间 問问 門门 隱隐 際际 雖虽 難难 離离 雜杂 雞鸡 鳥鸟
        魚鱼 點点 熱热 於于 與与 為为 無无 麼么 幾几 後后 從从 們们 個个 價价 優优
        傳传 傷伤 單单 廠厂 衛卫 壓压 醫医 學学 寧宁 寶宝 實实 將将 專专 對对 導导
        島岛 師师 帶带 幫帮 廣广 彈弹 復复 恆恒 惡恶 慶庆 應应 戰战 戲戏 擔担 擊击
        數数 斷断 氣气 漢汉 滿满 潔洁 燈灯 爭争 獎奖 獲获 現现 環环 產产 發发 盡尽
        監监 網网 緊紧 線线 練练 組组 細细 終终 結结 給给 統统 絕绝 續续 維维 綠绿
        義义 習习 聖圣 聯联 聰聪 職职 腦脑 臉脸 臨临 興兴 舉举 舊旧 藝艺 蓮莲 蘋苹
        號号 補补 裝装 裡里 見见 規规 視视 親亲 覺觉 觀观 計计 訂订 訊讯 講讲 論论
        設设 訪访 評评 詞词 試试 詩诗 該该 詳详 誌志 認认 誠诚 課课 調调 談谈 請请
        諸诸 諾诺 謀谋 證证 識识 譜谱 議议 護护 讚赞 負负 財财 貢贡 貧贫 貨货 販贩
        貪贪 責责 貴贵 買买 資资 賜赐 賣卖 購购 贈赠 贏赢 趕赶 跡迹 踐践 軟软 較较
        載载 輕轻 輛辆 輪轮 輸输 轉转 辭辞 農农 遠远 適适 選选 遺遗 遲迟 鄉乡 郵邮
        鄰邻 釋释 針针 銀银 銅铜 銷销 鋼钢 錄录 錦锦 鍵键 鐵铁 長长 閉闭 閑闲 閔闵
        閱阅 陣阵 陸陆 隊队 階阶 隨随 險险 隻只 頂顶 項项 順顺 須须 預预 頓顿 頭头
        頻频 顆颗 題题 顯显 飯饭 飲饮 飾饰 養养 館馆 駕驾 驗验 騎骑 體体 髮发 鮮鲜
        鴻鸿 麥麦 黨党 齒齿 龜龟 謙谦 輝辉 瑋玮 緯纬 凱凯 鈞钧 瑩莹 頌颂 韻韵 樺桦
        燁烨 燦灿 爍烁 煒炜 彥彦 綺绮 蕓芸 篤笃 嶽岳
        """

        var map: [Character: Character] = [:]
        for pair in raw.split(whereSeparator: { $0.isWhitespace }) where pair.count == 2 {
            if let trad = pair.first, let simp = pair.last {
                map[trad] = simp
            }
        }
        return map
    }()

    /// 繁体转简体（表里没有的字原样保留）
    static func simplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var changed = false
        let mapped = text.map { char -> Character in
            if let simple = tradToSimp[char] {
                changed = true
                return simple
            }
            return char
        }
        return changed ? String(mapped) : text
    }
}
