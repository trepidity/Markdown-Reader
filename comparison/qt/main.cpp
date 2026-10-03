#include <QtWidgets/QtWidgets>
#include "mvcore.h"

class SafeBrowser : public QTextBrowser {
 QVariant loadResource(int type, const QUrl &url) override {
  if(type==QTextDocument::ImageResource && url.scheme()=="data") {auto s=url.toString();return QImage::fromData(QByteArray::fromBase64(s.mid(s.indexOf(',')+1).toLatin1()));}
  return QVariant();
 }
};
class Viewer : public QMainWindow {
 QJsonObject state; QLineEdit *path,*query; SafeBrowser *preview; QPlainTextEdit *editor; QStackedWidget *pages; QLabel *status; QComboBox *files,*docs,*scope,*results,*themes; QJsonArray matches; bool applying=false;
 QJsonObject command(QJsonObject c) {
  auto raw=QJsonDocument(c).toJson(QJsonDocument::Compact);char *res=MVCommand(raw.data());auto s=QJsonDocument::fromJson(res).object();MVFree(res);
  if(c["action"]!="search"&&!s["unchanged"].toBool())apply(s,c["action"].toString());return s;
 }
 void apply(QJsonObject s,QString action) {
  if(action=="refresh"&&!s["reloadedPaths"].toArray().contains(state["path"])){status->setText(s["watchError"].toString());return;}
  bool changed=s["path"]!=state["path"],render=changed||s["html"]!=state["html"]||s["theme"]!=state["theme"];state=s;applying=true;
  setWindowTitle(QFileInfo(s["path"].toString()).fileName()+" — Qt Widgets");
  if(changed||QStringList{"undo","redo","reload","refresh"}.contains(action))editor->setPlainText(s["text"].toString());
  if(changed)pages->setCurrentIndex(0);
  auto theme=s["theme"].toString();QString bg=theme=="night"?"#202226":theme=="sepia"?"#f2e8d4":"#fafafa",fg=theme=="night"?"#f4f4f4":"#202020";
  if(render){preview->document()->setDefaultStyleSheet("body {font-family:Georgia;font-size:17px;color:"+fg+"} h1 {font-size:30px} pre,code {font-family:Menlo} td,th {border:1px solid #888;padding:7px} blockquote {margin-left:24px}");QString html=s["html"].toString();html.replace(QRegularExpression("<input[^>]*checked[^>]*>"),QString::fromUtf8("☑ "));html.replace(QRegularExpression("<input[^>]*>"),QString::fromUtf8("☐ "));preview->document()->setDefaultFont(QFont("Georgia",17));preview->setHtml("<html><body>"+(html.isEmpty()?"<h2>Open a Markdown document to compare Qt Widgets rendering.</h2>":html)+"</body></html>");}
  preview->setStyleSheet("QTextBrowser {background:"+bg+";color:"+fg+";padding:24px}");editor->setStyleSheet("QPlainTextEdit {background:"+bg+";color:"+fg+";padding:24px}");themes->setCurrentText(theme);
  files->clear();files->addItem("Folder files");for(auto v:s["files"].toArray())files->addItem(QFileInfo(v.toString()).fileName(),v.toString());
  docs->clear();docs->addItem("Open / recent documents");QStringList seen;for(auto key:{"openDocuments","recent"})for(auto v:s[key].toArray())if(!seen.contains(v.toString())){seen<<v.toString();docs->addItem(QFileInfo(v.toString()).fileName(),v.toString());}
  status->setText(!s["error"].toString().isEmpty()?s["error"].toString():s["dirty"].toBool()?"Unsaved changes":"All changes saved — Qt Widgets / QTextDocument");applying=false;
 }
 void link(QUrl url){auto href=url.toString();if(href.startsWith('#'))preview->scrollToAnchor(href.mid(1));else if(QStringList{"https","http","mailto"}.contains(url.scheme()))QDesktopServices::openUrl(url);else command({{"action","navigateLink"},{"path",state["path"]},{"href",href}});}
 void find(){auto s=command({{"action","search"},{"query",query->text()},{"scope",scope->currentData().toString()}});matches=s["search"].toObject()["matches"].toArray();results->clear();results->addItem(QString::number(matches.size())+" matches — choose to open");for(auto v:matches){auto m=v.toObject();results->addItem(QFileInfo(m["path"].toString()).fileName()+":"+QString::number(m["line"].toInt())+" "+m["snippet"].toString());}}
 bool flush(){auto s=command({{"action","flush"}});return !s["dirty"].toBool()&&s["error"].toString().isEmpty();}
 protected:void closeEvent(QCloseEvent *e)override{if(flush())e->accept();else e->ignore();}
 public:Viewer(){MVInitialize((char*)"Qt");resize(1080,780);auto root=new QWidget;auto layout=new QVBoxLayout(root);setCentralWidget(root);
 auto top=new QHBoxLayout;layout->addLayout(top);auto button=[&](QHBoxLayout *row,QString name,auto cb){auto b=new QPushButton(name);row->addWidget(b);connect(b,&QPushButton::clicked,this,cb);return b;};
 button(top,"Open…",[&]{auto p=QFileDialog::getOpenFileName(this,"Open Markdown");if(!p.isEmpty())command({{"action","open"},{"path",p}});});
 path=new QLineEdit;path->setPlaceholderText("File or folder path");top->addWidget(path,1);auto load=[&]{command({{"action","open"},{"path",path->text()}});};button(top,"Load path",load);connect(path,&QLineEdit::returnPressed,this,load);
 button(top,"Preview / Edit",[&]{pages->setCurrentIndex(1-pages->currentIndex());if(pages->currentIndex())editor->setFocus();});button(top,"Undo",[&]{command({{"action","undo"}});});button(top,"Redo",[&]{command({{"action","redo"}});});button(top,"Save Copy…",[&]{auto p=QFileDialog::getSaveFileName(this,"Save copy","Copy.md");if(!p.isEmpty())command({{"action","saveAs"},{"path",p}});});
 auto bar=new QHBoxLayout;layout->addLayout(bar);files=new QComboBox;docs=new QComboBox;for(auto p:{files,docs}){bar->addWidget(p,1);connect(p,&QComboBox::activated,this,[&,p](int i){if(i>0)command({{"action","navigate"},{"path",p->itemData(i).toString()}});});}
 button(bar,"Close document",[&]{command({{"action","closeDocument"}});});button(bar,"Reload…",[&]{if(QMessageBox::question(this,"Reload","Discard draft and reload?")==QMessageBox::Yes)command({{"action","reload"}});});themes=new QComboBox;themes->addItems({"paper","night","sepia"});bar->addWidget(themes);connect(themes,&QComboBox::activated,this,[&](int){if(!applying)command({{"action","settings"},{"theme",themes->currentText()},{"style","serif"}});});
 auto search=new QHBoxLayout;layout->addLayout(search);query=new QLineEdit;query->setPlaceholderText("Find text");search->addWidget(query);scope=new QComboBox;scope->addItem("This document","current");scope->addItem("Open documents","open");scope->addItem("Folder","folder");search->addWidget(scope);button(search,"Find",[&]{find();});connect(query,&QLineEdit::returnPressed,this,[&]{find();});results=new QComboBox;search->addWidget(results,1);connect(results,&QComboBox::activated,this,[&](int i){if(i<1)return;auto m=matches[i-1].toObject();auto s=command({{"action","navigate"},{"path",m["path"]}});if(!s["error"].toString().isEmpty())return;pages->setCurrentIndex(1);QTextCursor c(editor->document());c.setPosition(m["start"].toInt());c.setPosition(m["end"].toInt(),QTextCursor::KeepAnchor);editor->setTextCursor(c);editor->setFocus();});
 pages=new QStackedWidget;preview=new SafeBrowser;preview->setOpenLinks(false);preview->setOpenExternalLinks(false);connect(preview,&QTextBrowser::anchorClicked,this,[&](QUrl u){link(u);});editor=new QPlainTextEdit;editor->setFont(QFont("Menlo",14));editor->setUndoRedoEnabled(false);connect(editor,&QPlainTextEdit::textChanged,this,[&]{if(!applying)command({{"action","edit"},{"path",state["path"]},{"revision",state["revision"]},{"text",editor->toPlainText()}});});pages->addWidget(preview);pages->addWidget(editor);layout->addWidget(pages,1);status=new QLabel;layout->addWidget(status);
 auto shortcut=[&](QKeySequence key,auto cb){auto a=new QShortcut(key,this);connect(a,&QShortcut::activated,this,cb);};shortcut(QKeySequence::Undo,[&]{command({{"action","undo"}});});shortcut(QKeySequence::Redo,[&]{command({{"action","redo"}});});shortcut(QKeySequence::Find,[&]{query->setFocus();});shortcut(QKeySequence("Ctrl+E"),[&]{pages->setCurrentIndex(1-pages->currentIndex());});
 command({{"action","state"}});auto args=QCoreApplication::arguments();if(args.size()>1)command({{"action","open"},{"path",args[1]}});auto timer=new QTimer(this);connect(timer,&QTimer::timeout,this,[&]{if(!state["openDocuments"].toArray().isEmpty())command({{"action","refresh"}});});timer->start(750);
 }
};
int main(int argc,char **argv){QApplication app(argc,argv);Viewer v;v.show();return app.exec();}
